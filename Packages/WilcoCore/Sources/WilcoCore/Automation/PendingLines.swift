import Foundation

/// Remembers what rules heard in a recognised line until its voice-annotated
/// pieces arrive, so each piece can be stored with the keywords it said.
///
/// Rules fire on the whole recognised line; the transcript stores the pieces
/// voice analysis splits it into. A keyword goes to the piece that holds it.
/// One that no single piece holds (a phrase split across a voice change, say)
/// goes to the piece where it starts, which for a phrase found nowhere is the
/// first piece. Bounded by count and age, so a line whose annotation never
/// comes (its channel stopped, say) is forgotten.
public struct PendingLines: Sendable {
    private struct Line: Sendable {
        var id: UUID
        var date: Date
        var keywords: [String]
        /// Words of the line not yet covered by an arrived piece.
        var remaining: [String]
        /// Lowercased keywords already given to a piece.
        var assigned: Set<String> = []
    }

    public let maximumLines: Int
    public let maximumAge: TimeInterval
    /// Oldest first.
    private var lines: [Line] = []

    public init(maximumLines: Int = 64, maximumAge: TimeInterval = 60) {
        self.maximumLines = maximumLines
        self.maximumAge = maximumAge
    }

    /// Lines still waiting for pieces.
    public var count: Int { lines.count }

    /// Records a recognised line and the keywords its rules heard.
    public mutating func recognized(_ lineID: UUID, text: String, keywords: [String], at date: Date) {
        prune(at: date)
        lines.removeAll { $0.id == lineID }
        lines.append(Line(id: lineID, date: date, keywords: keywords, remaining: KeywordMatcher.tokens(text)))
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }

    /// The keywords for the next piece of a line, which arrive in order. The
    /// line is forgotten once its pieces have covered all its words.
    public mutating func keywords(forPiece text: String, of lineID: UUID, at date: Date) -> [String] {
        prune(at: date)
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return [] }
        var line = lines[index]
        let pieceWords = KeywordMatcher.tokens(text)
        let after = Array(line.remaining.dropFirst(pieceWords.count)).joined(separator: " ")
        let found = line.keywords.filter { keyword in
            if !AutomationEvaluator.keywords([keyword], in: text).isEmpty { return true }
            // Not in this piece: it's this piece's if it isn't wholly in a later one.
            return !line.assigned.contains(keyword.lowercased())
                && AutomationEvaluator.keywords([keyword], in: after).isEmpty
        }
        line.assigned.formUnion(found.map { $0.lowercased() })
        line.remaining = Array(line.remaining.dropFirst(pieceWords.count))
        if line.remaining.isEmpty {
            lines.remove(at: index)
        } else {
            lines[index] = line
        }
        return found
    }

    private mutating func prune(at date: Date) {
        lines.removeAll { date.timeIntervalSince($0.date) > maximumAge }
    }
}
