import Foundation

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

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }
}
