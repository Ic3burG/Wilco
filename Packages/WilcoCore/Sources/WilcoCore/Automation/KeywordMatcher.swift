import Foundation
import Synchronization

/// Decides whether a rule's phrases were heard in a line.
///
/// Matching is by whole words, case- and punctuation-insensitive, and
/// ignores how words are split: speech engines variously write "standby" and
/// "stand by", so a phrase matches any run of words that spells it once the
/// spaces are removed. "go" still never matches "going".
public enum KeywordMatcher {
    /// The phrases that matched, or empty when the rule does not match.
    public static func matches(_ phrases: [String], in text: String, mode: KeywordMatchMode) -> [String] {
        let phrases = phrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !phrases.isEmpty else { return [] }

        switch mode {
        case .regularExpression:
            return phrases.compactMap { firstMatch(of: $0, in: text) }
        case .containsAny:
            let words = tokens(text)
            return phrases.filter { contains(words, tokens($0), anchored: false) }
        case .containsAll:
            let words = tokens(text)
            return phrases.allSatisfy({ contains(words, tokens($0), anchored: false) }) ? phrases : []
        case .startsWith:
            let words = tokens(text)
            return phrases.filter { contains(words, tokens($0), anchored: true) }
        }
    }

    /// Lowercased words with punctuation removed. Apostrophes join a word
    /// ("that's" stays one word) rather than splitting it.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The first of `phrases` (already split into words) found in `words`.
    /// For callers checking many phrase lists against one line.
    static func firstMatch(of phrases: [(phrase: String, words: [String])], in words: [String]) -> String? {
        phrases.first { contains(words, $0.words, anchored: false) }?.phrase
    }

    private static func contains(_ words: [String], _ phrase: [String], anchored: Bool) -> Bool {
        guard !phrase.isEmpty, !words.isEmpty else { return false }
        let target = phrase.joined()
        let starts = anchored ? 0..<1 : 0..<words.count
        for start in starts {
            var joined = ""
            for end in start..<words.count {
                joined += words[end]
                if joined == target { return true }
                if joined.count >= target.count || !target.hasPrefix(joined) { break }
            }
        }
        return false
    }

    // MARK: Regular expressions

    /// Patterns longer than this never match.
    public static let maximumPatternLength = 500
    /// Only this many characters at the start of a line are searched.
    /// Speech lines are far shorter; this bounds the work on a runaway one.
    public static let maximumRegexTextLength = 2_000

    /// Whether `pattern` is short enough and free of nested repeats such as
    /// `(a+)+`. Matching runs on every line heard, and patterns like that can
    /// take exponential time on a line that almost matches, which would
    /// stall the app mid-show. Patterns come from show files, which may come
    /// from anyone.
    public static func isSafePattern(_ pattern: String) -> Bool {
        pattern.count <= maximumPatternLength && !hasNestedRepeat(pattern)
    }

    /// Longest one pattern may spend on one line. Matching runs on the main
    /// thread, so this is the longest a pattern can hold up the window.
    public static let regexTimeLimit: Double = 0.05

    /// Patterns that ran past ``regexTimeLimit`` since launch. They never
    /// match again until the app restarts, so a slow pattern costs one
    /// short pause, not one per line.
    public static var stalledPatterns: Set<String> {
        cache.withLock { cache in Set(cache.filter(\.value.stalled).keys) }
    }

    /// Stalled patterns not yet reported, for the Activity log. Each is
    /// returned once.
    public static func takeNewlyStalled() -> [String] {
        newlyStalled.withLock { patterns in
            defer { patterns.removeAll() }
            return patterns
        }
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let expression = compiled(pattern) else { return nil }
        let searched = String(text.prefix(maximumRegexTextLength))
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(regexTimeLimit * 1e9)
        var match: NSTextCheckingResult?
        var timedOut = false
        // The static check can't see every slow pattern (overlapping
        // alternatives such as `(.|..)+!` pass it), so the engine reports
        // progress and the search is stopped at the deadline.
        expression.enumerateMatches(
            in: searched, options: [.reportProgress], range: NSRange(searched.startIndex..., in: searched)
        ) { result, _, stop in
            if let result {
                match = result
                stop.pointee = true
            } else if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut {
            cache.withLock { $0[pattern] = Compiled(expression: nil, stalled: true) }
            newlyStalled.withLock { $0.append(pattern) }
            return nil
        }
        guard let match, let range = Range(match.range, in: searched) else { return nil }
        return String(searched[range])
    }

    /// NSRegularExpression is immutable and safe to share between threads.
    private struct Compiled: @unchecked Sendable {
        let expression: NSRegularExpression?
        var stalled = false
    }

    private static let cache = Mutex<[String: Compiled]>([:])
    private static let newlyStalled = Mutex<[String]>([])
    private static let cacheLimit = 256

    /// Compiled once per pattern rather than on every line; `nil` when the
    /// pattern is unsafe, has stalled or doesn't compile.
    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        if let hit = cache.withLock({ $0[pattern] }) { return hit.expression }
        let expression = isSafePattern(pattern)
            ? try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            : nil
        cache.withLock { cache in
            // Stalled patterns are kept, or a full cache would let them run again.
            if cache.count >= cacheLimit { cache = cache.filter(\.value.stalled) }
            cache[pattern] = Compiled(expression: expression)
        }
        return expression
    }

    /// True when a group that contains an unbounded repeat (`*`, `+`,
    /// `{n,}`) is itself repeated without bound. Escapes and character
    /// classes are skipped, so `(a\+)+` and `(x[+*])+` are fine.
    static func hasNestedRepeat(_ pattern: String) -> Bool {
        let chars = Array(pattern.unicodeScalars)
        /// For each open group, whether it contains an unbounded repeat.
        var groups: [Bool] = []
        var i = 0

        func unboundedRepeat(at index: Int) -> (length: Int, unbounded: Bool)? {
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "*", "+": return (1, true)
            case "?": return (1, false)
            case "{":
                var j = index + 1
                var body = ""
                while j < chars.count, chars[j] != "}" { body.unicodeScalars.append(chars[j]); j += 1 }
                guard j < chars.count, body.first?.isNumber == true,
                      body.allSatisfy({ $0.isNumber || $0 == "," }) else { return nil }
                return (j - index + 1, body.hasSuffix(","))
            default: return nil
            }
        }

        while i < chars.count {
            switch chars[i] {
            case "\\":
                i += 2
            case "[":
                i += 1
                if i < chars.count, chars[i] == "^" { i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }
                while i < chars.count, chars[i] != "]" {
                    i += chars[i] == "\\" ? 2 : 1
                }
                i += 1
            case "(":
                groups.append(false)
                i += 1
            case ")":
                let inner = groups.popLast() ?? false
                i += 1
                if let repeat_ = unboundedRepeat(at: i), repeat_.unbounded, inner { return true }
                if inner, !groups.isEmpty { groups[groups.count - 1] = true }
            default:
                if let repeat_ = unboundedRepeat(at: i) {
                    if repeat_.unbounded, !groups.isEmpty { groups[groups.count - 1] = true }
                    i += repeat_.length
                } else {
                    i += 1
                }
            }
        }
        return false
    }
}
