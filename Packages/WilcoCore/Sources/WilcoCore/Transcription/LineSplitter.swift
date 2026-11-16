import Foundation

/// A recognised word and when it was spoken, in session offsets (seconds).
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Cuts a final line where the voice changes, between words.
public enum LineSplitter {
    /// The line as one or more lines, one per voice. Each change goes at the
    /// gap between words nearest the change time (a change inside a gap goes
    /// there; one inside a word goes to the nearer edge). A piece left with no
    /// words is dropped, and neighbours with the same voice join up.
    ///
    /// The line stays whole, with its longest piece's voice, when there is
    /// one piece, no words, or words that can't be found in `text` in order
    /// (the text was changed after it was timed). Pieces always use `text`'s
    /// own spelling, so the split lines read exactly as the line sent to rules.
    public static func split(
        words: [TimedWord], text: String, pieces: [VoicePiece]
    ) -> [(text: String, start: Double, voice: String?, exchange: Int)] {
        let longest = pieces.enumerated().max { a, b in
            // Ties go to the earlier piece.
            let (da, db) = (a.element.end - a.element.start, b.element.end - b.element.start)
            return da != db ? da < db : a.offset > b.offset
        }?.element
        let whole = [(
            text: text, start: pieces.first?.start ?? words.first?.start ?? 0,
            voice: longest?.voice, exchange: longest?.exchange ?? 1
        )]

        let timed = placeableWords(words, in: text)
        guard pieces.count > 1, !timed.isEmpty, let positions = locate(timed, in: text) else { return whole }

        // cuts[i] is the index of piece i's first word.
        let cuts = [0] + Self.cuts(at: pieces.dropFirst().map(\.start), words: timed) + [timed.count]

        // Pieces with words; neighbours with the same voice join up.
        var kept: [(first: Int, voice: String?, exchange: Int)] = []
        for (i, piece) in pieces.enumerated() where cuts[i] < cuts[i + 1] {
            if let last = kept.last, last.voice == piece.voice, last.exchange == piece.exchange { continue }
            kept.append((cuts[i], piece.voice, piece.exchange))
        }
        guard kept.count > 1 else {
            let only = kept.first
            return [(text: text, start: whole[0].start, voice: only?.voice, exchange: only?.exchange ?? whole[0].exchange)]
        }

        var out: [(text: String, start: Double, voice: String?, exchange: Int)] = []
        for (i, part) in kept.enumerated() {
            let from = i == 0 ? text.startIndex : positions[part.first]
            let to = i == kept.count - 1 ? text.endIndex : positions[kept[i + 1].first]
            let start = i == 0 ? whole[0].start : timed[part.first].start
            out.append((
                text: text[from..<to].trimmingCharacters(in: .whitespacesAndNewlines),
                start: start, voice: part.voice, exchange: part.exchange
            ))
        }
        return out
    }

    /// The words a line can be cut at: those with letters or digits, in time
    /// order, when every one of them can be found in `text` in order. Empty
    /// otherwise, which keeps the line whole.
    public static func placeableWords(_ words: [TimedWord], in text: String) -> [TimedWord] {
        let timed = words.filter { !core($0.text).isEmpty }.sorted { $0.start < $1.start }
        return locate(timed, in: text) == nil ? [] : timed
    }

    /// Where each change time cuts `words` (from ``placeableWords(_:in:)``):
    /// the index of the first word after the cut, at the gap nearest the
    /// change. Never decreasing; `words.count` means after the last word.
    public static func cuts(at changes: [Double], words: [TimedWord]) -> [Int] {
        var out: [Int] = []
        for time in changes {
            let nearest = (0...words.count).min { gapDistance(time, $0, words) < gapDistance(time, $1, words) }!
            out.append(max(nearest, out.last ?? 0))
        }
        return out
    }

    /// How far `time` is from the gap before word `k` (`k == count` is the
    /// gap after the last word). Zero inside the gap.
    private static func gapDistance(_ time: Double, _ k: Int, _ words: [TimedWord]) -> Double {
        let from = k == 0 ? -Double.infinity : words[k - 1].end
        let to = k == words.count ? Double.infinity : words[k].start
        if time < from { return from - time }
        if time > to { return time - to }
        return 0
    }

    /// Where each word starts in `text`, matching letters and digits only,
    /// ignoring case. Nil if any word can't be found in order.
    private static func locate(_ words: [TimedWord], in text: String) -> [String.Index]? {
        var cursor = text.startIndex
        var out: [String.Index] = []
        for word in words {
            guard let found = text.range(
                of: core(word.text), options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex
            ) else { return nil }
            out.append(found.lowerBound)
            cursor = found.upperBound
        }
        return out
    }

    /// A word without the spaces and punctuation around it.
    private static func core(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }
}
