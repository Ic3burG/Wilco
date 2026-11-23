import Foundation

/// How often each name-like word or pair was heard: capitalised words that
/// don't start a sentence, and short acronyms. Adds up across sessions.
public struct NameCounts: Sendable, Equatable {
    public var counts: [String: Int] = [:]

    public init(counts: [String: Int] = [:]) { self.counts = counts }

    public static func make(_ segments: [TranscriptSegment]) -> NameCounts {
        var names = NameCounts()
        for segment in segments { names.count(segment.text) }
        return names
    }

    public mutating func add(_ other: NameCounts) {
        counts.merge(other.counts, uniquingKeysWith: +)
    }

    private mutating func count(_ text: String) {
        var sentenceStart = true
        var previous: String?  // the last word, when it can start a pair
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.subtracting(["'", "-"]))
            let breaksAfter = raw.last.map { ",.;:!?".contains($0) } ?? false
            let endsSentence = raw.last.map { ".!?".contains($0) } ?? false
            defer { sentenceStart = endsSentence }
            guard !word.isEmpty, Self.isCapitalised(word), !Self.isIgnored(word) else {
                previous = nil
                continue
            }
            if !sentenceStart {
                if Self.isNameWord(word) { counts[word, default: 0] += 1 }
                if let previous { counts["\(previous) \(word)", default: 0] += 1 }
            }
            previous = breaksAfter || sentenceStart ? nil : word
        }
    }

    static func isCapitalised(_ word: String) -> Bool { word.first?.isUppercase ?? false }

    /// Fillers, chatter and "I", which are capitalised without being names.
    static func isIgnored(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return lowered == "i" || lowered.hasPrefix("i'") || SessionStats.fillerWords.contains(lowered)
            || exclamations.contains(lowered)
            || ShowReportBuilder.stopWords.contains(lowered.replacingOccurrences(of: "'", with: ""))
    }

    /// Capitalised in speech without being anyone on comms.
    static let exclamations: Set<String> = ["god", "jesus", "christ", "lord", "gosh"]

    /// Single words need two letters; a lone "T" only counts inside a pair.
    static func isNameWord(_ word: String) -> Bool { word.filter(\.isLetter).count >= 2 }
}

public struct VocabularySuggestion: Sendable, Hashable {
    public var term: String
    /// What was heard instead, when the term is a channel name heard wrong.
    public var heardAs: String?
    public var count: Int

    public init(term: String, heardAs: String? = nil, count: Int) {
        self.term = term
        self.heardAs = heardAs
        self.count = count
    }
}

public enum VocabularySuggestions {
    public static let maximum = 8
    /// Shorter names match ordinary words too easily ("BOD" / "God").
    public static let minimumNearMissLetters = 5

    /// Channel names heard wrong first, then names heard often, leaving out
    /// anything the show's vocabulary, rules or highlights already know.
    public static func suggest(counts: NameCounts, show: ShowDocument, minimum: Int = 3) -> [VocabularySuggestion] {
        let known = Set((show.globalVocabulary + show.rules.flatMap(\.phrases) + show.highlights.flatMap(\.phrases))
            .map { $0.lowercased() })
        let channelNames = Set(show.channels.map { $0.name.trimmingCharacters(in: .whitespaces) })

        var nearMisses: [VocabularySuggestion] = []
        for name in channelNames.sorted() where !known.contains(name.lowercased()) {
            let target = letters(name)
            let words = name.split(separator: " ").count
            guard target.count >= minimumNearMissLetters else { continue }
            let heardRight = counts.counts[name] ?? 0
            let best = counts.counts
                .filter { phrase, count in
                    count >= minimum && count > heardRight && phrase != name
                        && phrase.split(separator: " ").count == words
                        && { let d = distance(letters(phrase), target); return d * 3 <= target.count }()
                }
                .max { ($0.value, $1.key) < ($1.value, $0.key) }
            if let best { nearMisses.append(VocabularySuggestion(term: name, heardAs: best.key, count: best.value)) }
        }

        // A word heard mostly inside a pair ("Time" in "T Time") isn't a name on its own.
        var alone = counts.counts
        for (phrase, count) in counts.counts where phrase.contains(" ") {
            for word in phrase.split(separator: " ") { alone[String(word), default: 0] -= count }
        }
        let taken = Set(nearMisses.flatMap { [$0.term.lowercased(), $0.heardAs?.lowercased() ?? ""] })
        let plain = alone
            .filter { phrase, count in
                count >= minimum && !known.contains(phrase.lowercased()) && !taken.contains(phrase.lowercased())
                    && !channelNames.contains(phrase)
            }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { VocabularySuggestion(term: $0.key, count: $0.value) }

        return Array((nearMisses.sorted { $0.count > $1.count } + plain).prefix(maximum))
    }

    static func letters(_ text: String) -> [Character] { Array(text.lowercased().filter(\.isLetter)) }

    /// Levenshtein distance.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let saved = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = saved
            }
        }
        return row[b.count]
    }
}
