import Testing
@testable import WilcoCore

@Suite("Line splitter")
struct LineSplitterTests {
    private func w(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    private func piece(_ voice: String?, _ start: Double, _ end: Double, exchange: Int = 1) -> VoicePiece {
        VoicePiece(start: start, end: end, voice: voice, exchange: exchange)
    }

    private let words = [
        TimedWord(text: "Standby", start: 0, end: 0.5),
        TimedWord(text: "LX", start: 0.5, end: 0.8),
        TimedWord(text: "42", start: 0.8, end: 1.2),
        TimedWord(text: "Standing", start: 1.6, end: 2.0),
        TimedWord(text: "by", start: 2.0, end: 2.3),
    ]

    @Test func splitsAtTheWordNearestTheChange() {
        let out = LineSplitter.split(
            words: words, text: "Standby LX 42 Standing by", pieces: [piece("A", 0, 1.4), piece("B", 1.4, 2.3)]
        )
        #expect(out.map(\.text) == ["Standby LX 42", "Standing by"])
        #expect(out.map(\.voice) == ["A", "B"])
        #expect(out.map(\.start) == [0, 1.6])
        #expect(out.map(\.exchange) == [1, 1])
    }

    @Test func keepsTheLinesOwnSpellingAndPunctuation() {
        // The engine's words lack the line's punctuation and capitals.
        let lower = [w("standby", 0, 0.5), w("lx", 0.5, 0.8), w("42", 0.8, 1.2), w("standing", 1.6, 2.0), w("by", 2.0, 2.3)]
        let out = LineSplitter.split(
            words: lower, text: "Standby, LX 42. Standing by.", pieces: [piece("A", 0, 1.4), piece("B", 1.4, 3.0)]
        )
        #expect(out.map(\.text) == ["Standby, LX 42.", "Standing by."])
    }

    @Test func changeInsideAWordMovesToTheNearestGap() {
        // The change lands inside "Standing"; the gap before it is nearer
        // than the one after.
        let out = LineSplitter.split(
            words: words, text: "Standby LX 42 Standing by", pieces: [piece("A", 0, 1.75), piece("B", 1.75, 2.3)]
        )
        #expect(out.map(\.text) == ["Standby LX 42", "Standing by"])
    }

    @Test func trailingSilenceDoesNotMoveTheSplit() {
        // The line ends 0.7 s after its last word (the pause that closed it).
        let out = LineSplitter.split(
            words: words, text: "Standby LX 42 Standing by", pieces: [piece("A", 0, 1.5), piece("B", 1.5, 3.0)]
        )
        #expect(out.map(\.text) == ["Standby LX 42", "Standing by"])
        #expect(out.map(\.start) == [0, 1.6])
    }

    @Test func noWordsKeepsTheLineWhole() {
        let out = LineSplitter.split(
            words: [], text: "Standby LX 42 Standing by",
            pieces: [piece("A", 0, 0.9), piece("B", 0.9, 2.3, exchange: 2)]
        )
        #expect(out.count == 1)
        #expect(out.first?.text == "Standby LX 42 Standing by")
        #expect(out.first?.voice == "B")
        #expect(out.first?.exchange == 2)
        #expect(out.first?.start == 0)
    }

    @Test func onePieceKeepsTheLineWhole() {
        let out = LineSplitter.split(words: words, text: "Standby LX 42 Standing by", pieces: [piece("C", 0, 2.3)])
        #expect(out.map(\.text) == ["Standby LX 42 Standing by"])
        #expect(out.map(\.voice) == ["C"])
    }

    @Test func pieceWithoutWordsMergesIntoNeighbour() {
        // B covers only the silence after the last word: it has no words to
        // show, so the line stays A.
        let out = LineSplitter.split(
            words: words, text: "Standby LX 42 Standing by",
            pieces: [piece("A", 0, 2.4), piece("B", 2.4, 3.3)]
        )
        #expect(out.map(\.text) == ["Standby LX 42 Standing by"])
        #expect(out.map(\.voice) == ["A"])
    }

    @Test func emptyMiddlePieceJoinsTheSameVoiceEitherSide() {
        // A, then B over no words, then A again: one A line.
        let out = LineSplitter.split(
            words: words, text: "Standby LX 42 Standing by",
            pieces: [piece("A", 0, 1.3), piece("B", 1.3, 1.45), piece("A", 1.45, 2.3)]
        )
        #expect(out.map(\.text) == ["Standby LX 42 Standing by"])
        #expect(out.map(\.voice) == ["A"])
    }

    @Test func threeVoicesGiveThreeLines() {
        let calls = [
            w("Standby", 0, 0.5), w("LX", 0.5, 0.8), w("42", 0.8, 1.2),
            w("LX", 1.5, 1.8), w("standing", 1.8, 2.2), w("by", 2.2, 2.4),
            w("Sound", 2.8, 3.1), w("standing", 3.1, 3.5), w("by", 3.5, 3.8),
        ]
        let out = LineSplitter.split(
            words: calls, text: "Standby LX 42 LX standing by Sound standing by",
            pieces: [piece("A", 0, 1.3), piece("B", 1.3, 2.6), piece("C", 2.6, 4.5)]
        )
        #expect(out.map(\.text) == ["Standby LX 42", "LX standing by", "Sound standing by"])
        #expect(out.map(\.voice) == ["A", "B", "C"])
        #expect(out.map(\.start) == [0, 1.5, 2.8])
    }

    @Test func wordsThatDontMatchTheTextKeepTheLineWhole() {
        // The text was changed after timing, so the words can't be placed in
        // it: the line keeps the text that went to rules, whole.
        let out = LineSplitter.split(
            words: words, text: "Something else entirely", pieces: [piece("A", 0, 1.4), piece("B", 1.4, 2.3)]
        )
        #expect(out.map(\.text) == ["Something else entirely"])
        #expect(out.map(\.voice) == ["A"])
    }

    @Test func whisperStyleWordsWithLeadingSpacesAreFound() {
        let spaced = [w(" Standby", 0, 0.5), w(" LX", 0.5, 0.8), w(" 42.", 0.8, 1.2), w(" Standing", 1.6, 2.0), w(" by.", 2.0, 2.3)]
        let out = LineSplitter.split(
            words: spaced, text: "Standby LX 42. Standing by.", pieces: [piece("A", 0, 1.4), piece("B", 1.4, 2.3)]
        )
        #expect(out.map(\.text) == ["Standby LX 42.", "Standing by."])
    }
}
