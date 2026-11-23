import Foundation

/// Reduces a transcript to comparable words, so engines aren't marked wrong
/// for writing the same call differently ("Q5", "cue 5", "cue five").
public enum TranscriptNormalizer {
    public static func words(_ text: String) -> [String] {
        let cleaned = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "'" ? character : " "
        }
        var words: [String] = []
        for raw in String(cleaned).split(separator: " ") {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard !token.isEmpty else { continue }
            words.append(contentsOf: expand(token))
        }
        return joiningStandBy(words)
    }

    private static func expand(_ token: String) -> [String] {
        switch token {
        case "queue": return ["cue"]
        case "ok": return ["okay"]
        default: break
        }
        if let number = Int(token) { return spelled(number) }
        // Lighting desks write cue numbers as "Q5".
        if token.hasPrefix("q"), let number = Int(token.dropFirst()) { return ["cue"] + spelled(number) }
        return [token]
    }

    private static func joiningStandBy(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words {
            if word == "by", result.last == "stand" {
                result[result.count - 1] = "standby"
            } else {
                result.append(word)
            }
        }
        return result
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// English words for a whole number, without "and" ("one hundred five").
    static func spelled(_ number: Int) -> [String] {
        switch number {
        case ..<0: return ["minus"] + spelled(-number)
        case 0..<20: return [ones[number]]
        case 20..<100:
            return [tens[number / 10]] + (number % 10 == 0 ? [] : [ones[number % 10]])
        case 100..<1_000:
            return [ones[number / 100], "hundred"] + (number % 100 == 0 ? [] : spelled(number % 100))
        case 1_000..<1_000_000:
            return spelled(number / 1_000) + ["thousand"] + (number % 1_000 == 0 ? [] : spelled(number % 1_000))
        default:
            // Digit by digit, as people read long numbers out.
            return String(number).compactMap(\.wholeNumberValue).map { ones[$0] }
        }
    }
}

/// Word-level edit counts between a reference and what an engine wrote.
public struct WordErrors: Codable, Equatable, Sendable {
    public var substitutions = 0
    public var deletions = 0
    public var insertions = 0
    public var referenceWords = 0

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceWords: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    public var errors: Int { substitutions + deletions + insertions }

    /// Errors per reference word. Can exceed 1 when an engine invents words.
    public var rate: Double {
        guard referenceWords > 0 else { return insertions > 0 ? 1 : 0 }
        return Double(errors) / Double(referenceWords)
    }

    public static func + (lhs: WordErrors, rhs: WordErrors) -> WordErrors {
        WordErrors(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceWords: lhs.referenceWords + rhs.referenceWords
        )
    }
}

public enum WordErrorRate {
    /// The cheapest alignment of `hypothesis` onto `reference` (Levenshtein
    /// over words), broken down by kind of error.
    public static func compare(reference: [String], hypothesis: [String]) -> WordErrors {
        let n = reference.count, m = hypothesis.count
        if n == 0 || m == 0 {
            return WordErrors(deletions: n, insertions: m, referenceWords: n)
        }
        // Each cell: (total cost, substitutions, deletions, insertions).
        var previous = (0...m).map { (cost: $0, s: 0, d: 0, i: $0) }
        for row in 1...n {
            var current = [(cost: row, s: 0, d: row, i: 0)]
            current.reserveCapacity(m + 1)
            for column in 1...m {
                let match = reference[row - 1] == hypothesis[column - 1]
                let diagonal = previous[column - 1]
                let up = previous[column]
                let left = current[column - 1]
                var best = (cost: diagonal.cost + (match ? 0 : 1), s: diagonal.s + (match ? 0 : 1), d: diagonal.d, i: diagonal.i)
                if up.cost + 1 < best.cost { best = (up.cost + 1, up.s, up.d + 1, up.i) }
                if left.cost + 1 < best.cost { best = (left.cost + 1, left.s, left.d, left.i + 1) }
                current.append(best)
            }
            previous = current
        }
        let last = previous[m]
        return WordErrors(substitutions: last.s, deletions: last.d, insertions: last.i, referenceWords: n)
    }
}
