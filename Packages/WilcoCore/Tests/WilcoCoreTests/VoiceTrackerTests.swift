import Testing
@testable import WilcoCore

@Suite struct VoiceTrackerTests {
    /// Unit vector along axis `i`: distinct axes are orthogonal (distance 1).
    private func axis(_ i: Int, dims: Int = 32) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[i] = 1
        return v
    }

    private func vp(_ v: [Float], _ t0: Double, _ t1: Double) -> Voiceprint {
        Voiceprint(vector: v, start: t0, end: t1)
    }

    /// A line made of prints of `step` seconds each, one vector per print.
    private func line(_ vectors: [[Float]], from t0: Double, step: Double = 0.5) -> [Voiceprint] {
        vectors.enumerated().map { vp($1, t0 + Double($0) * step, t0 + Double($0 + 1) * step) }
    }

    private func letters(_ p: [VoicePiece]) -> [String?] { p.map(\.voice) }

    @Test func twoVoicesAlternatingGetTwoLetters() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        let a = t.assign(line([x, x, x], from: 0), lineStart: 0, lineEnd: 1.5)
        let b = t.assign(line([y, y, y], from: 2), lineStart: 2, lineEnd: 3.5)
        let c = t.assign(line([x, x, x], from: 4), lineStart: 4, lineEnd: 5.5)
        #expect(letters(a) == ["A"])
        #expect(letters(b) == ["B"])
        #expect(letters(c) == ["A"])
    }

    @Test func thirdVoiceGetsC() {
        var t = VoiceTracker(settings: .standard)
        var out: [String?] = []
        for (i, v) in [0, 1, 2, 0].enumerated() {
            let s = Double(i) * 2
            out += letters(t.assign(line([axis(v), axis(v), axis(v)], from: s), lineStart: s, lineEnd: s + 1.5))
        }
        #expect(out == ["A", "B", "C", "A"])
    }

    @Test func silenceLongerThanGapRestartsLetters() {
        var t = VoiceTracker(settings: .standard)
        let first = t.assign(line([axis(0), axis(0), axis(0)], from: 0), lineStart: 0, lineEnd: 1.5)
        let second = t.assign(line([axis(1), axis(1), axis(1)], from: 30), lineStart: 30, lineEnd: 31.5)
        #expect(letters(first) == ["A"])
        #expect(first.first?.exchange == 1)
        #expect(letters(second) == ["A"])
        #expect(second.first?.exchange == 2)
    }

    @Test func changeMidLineMakesTwoPieces() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        let pieces = t.assign(line([x, x, x, y, y, y], from: 0), lineStart: 0, lineEnd: 3)
        #expect(pieces == [
            VoicePiece(start: 0, end: 1.5, voice: "A", exchange: 1),
            VoicePiece(start: 1.5, end: 3, voice: "B", exchange: 1),
        ])
    }

    @Test func overlappingPrintsPlaceTheChangeBetweenTheirMiddles() {
        // 1.5 s prints every 0.5 s, as the voice model takes them. The last
        // old print is centred on 1.75 s and the first new one on 2.25 s; the
        // new one's start (1.5 s) would put the cut most of a word early.
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        let prints = [x, x, x, y, y, y, y].enumerated().map { vp($1, Double($0) * 0.5, Double($0) * 0.5 + 1.5) }
        let pieces = t.assign(prints, lineStart: 0, lineEnd: 5)
        #expect(pieces.map(\.start) == [0, 2.0])
        #expect(pieces.map(\.end) == [2.0, 5])
        #expect(letters(pieces) == ["A", "B"])
    }

    @Test func briefBlipDoesNotSplit() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        // Prints of 0.25 s; the odd one out sits at 0.5 s.
        let prints = line([x, x, y, x, x, x], from: 0, step: 0.25)
        let pieces = t.assign(prints, lineStart: 0, lineEnd: 1.5)
        #expect(pieces.count == 1)
        #expect(pieces.first?.voice == "A")
    }

    @Test func shortLineMatchesLooselyOrStaysUnknown() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0)
        _ = t.assign(line([x, x, x], from: 0), lineStart: 0, lineEnd: 1.5)

        // Distance 0.6 from A: over the 0.5 threshold, inside 0.625 (threshold x 1.25).
        var near = [Float](repeating: 0, count: 32)
        near[0] = 0.4
        near[1] = (1 - 0.16).squareRoot()
        let loose = t.assign([vp(near, 2, 2.6)], lineStart: 2, lineEnd: 2.6)
        #expect(letters(loose) == ["A"])

        let far = axis(5)
        let unknown = t.assign([vp(far, 3, 3.6)], lineStart: 3, lineEnd: 3.6)
        #expect(letters(unknown) == [nil])

        // The unknown blip created no voice: the next long line from that voice is B, not C.
        let next = t.assign(line([far, far, far], from: 4), lineStart: 4, lineEnd: 5.5)
        #expect(letters(next) == ["B"])
    }

    @Test func shortUnknownLineDoesNotMoveAnyMean() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0)
        _ = t.assign(line([x, x, x], from: 0), lineStart: 0, lineEnd: 1.5)
        for i in 0..<20 {
            let s = 2 + Double(i)
            _ = t.assign([vp(axis(5), s, s + 0.6)], lineStart: s, lineEnd: s + 0.6)
        }
        let again = t.assign(line([x, x, x], from: 23), lineStart: 23, lineEnd: 24.5)
        #expect(letters(again) == ["A"])
    }

    @Test func lineWithNoPrintsHasNoLetterAndChangesNothing() {
        var t = VoiceTracker(settings: .standard)
        _ = t.assign(line([axis(0), axis(0), axis(0)], from: 0), lineStart: 0, lineEnd: 1.5)
        let empty = t.assign([], lineStart: 2, lineEnd: 3)
        #expect(empty == [VoicePiece(start: 2, end: 3, voice: nil, exchange: 1)])
        let next = t.assign(line([axis(1), axis(1), axis(1)], from: 4), lineStart: 4, lineEnd: 5.5)
        #expect(letters(next) == ["B"])
    }

    @Test func unusableVectorsAreTreatedAsNoPrints() {
        var t = VoiceTracker(settings: .standard)
        _ = t.assign(line([axis(0), axis(0), axis(0)], from: 0), lineStart: 0, lineEnd: 1.5)
        let zero = t.assign(line([[Float](repeating: 0, count: 32)], from: 2), lineStart: 2, lineEnd: 3)
        #expect(letters(zero) == [nil])
        let wrongSize = t.assign(line([axis(0, dims: 8)], from: 4), lineStart: 4, lineEnd: 5)
        #expect(letters(wrongSize) == [nil])
        let nan = t.assign(line([[Float](repeating: .nan, count: 32)], from: 6), lineStart: 6, lineEnd: 7)
        #expect(letters(nan) == [nil])
    }

    @Test func lettersContinuePastZ() {
        var t = VoiceTracker(settings: .standard)
        var last: [String?] = []
        for i in 0..<28 {
            let s = Double(i) * 2
            last = letters(t.assign(line([axis(i), axis(i), axis(i)], from: s), lineStart: s, lineEnd: s + 1.5))
            if i == 0 { #expect(last == ["A"]) }
            if i == 25 { #expect(last == ["Z"]) }
            if i == 26 { #expect(last == ["AA"]) }
        }
        #expect(last == ["AB"])
        #expect(VoiceTracker.letter(0) == "A")
        #expect(VoiceTracker.letter(25) == "Z")
        #expect(VoiceTracker.letter(26) == "AA")
        #expect(VoiceTracker.letter(27) == "AB")
    }

    // MARK: - Only voices that are shown

    /// Words at 0–1.4 s and 3.1–4.4 s: nothing is said from 1.4 to 3.1 s.
    private let wordsAroundAGap = [
        TimedWord(text: "Standby", start: 0, end: 0.7), TimedWord(text: "LX", start: 0.7, end: 1.4),
        TimedWord(text: "LX", start: 3.1, end: 3.6), TimedWord(text: "go", start: 3.6, end: 4.4),
    ]

    /// Voice x, then voice y over the wordless middle only, then x again.
    private func lineWithAWordlessMiddleVoice(_ t: inout VoiceTracker) -> [VoicePiece] {
        let x = axis(0), y = axis(1)
        return t.assign(
            line([x, x, x, y, y, y, x, x, x], from: 0), lineStart: 0, lineEnd: 4.5, words: wordsAroundAGap
        )
    }

    @Test func wordlessPieceDoesNotTakeALetter() {
        var t = VoiceTracker(settings: .standard)
        let first = lineWithAWordlessMiddleVoice(&t)
        #expect(letters(first) == ["A", "A"])
        // The next new voice is the second one shown: B, not C.
        let next = t.assign(line([axis(2), axis(2), axis(2)], from: 6), lineStart: 6, lineEnd: 7.5, words: [
            TimedWord(text: "Standing", start: 6, end: 6.8), TimedWord(text: "by", start: 6.8, end: 7.2),
        ])
        #expect(letters(next) == ["B"])
    }

    @Test func wordlessPieceLeavesNoVoiceToMatch() {
        var t = VoiceTracker(settings: .standard)
        _ = lineWithAWordlessMiddleVoice(&t)
        // A short line in the dropped piece's voice: nobody shown sounds like
        // it, so it gets no letter rather than a letter never introduced.
        let y = axis(1)
        let short = t.assign([vp(y, 6, 6.5), vp(y, 6.3, 6.8)], lineStart: 6, lineEnd: 6.8, words: [
            TimedWord(text: "Copy", start: 6, end: 6.6),
        ])
        #expect(letters(short) == [nil])
    }

    @Test func lineWithoutWordsMakesOneVoiceAtMost() {
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        let whole = t.assign(line([x, x, x, y, y, y], from: 0), lineStart: 0, lineEnd: 3, words: [])
        #expect(whole.count == 1)
        #expect(letters(whole) == ["A"])
        // Only one voice was made, so a third speaker is B.
        let next = t.assign(line([axis(2), axis(2), axis(2)], from: 5), lineStart: 5, lineEnd: 6.5, words: [])
        #expect(letters(next) == ["B"])
    }

    @Test func piecesWithWordsAllGetLetters() {
        // Words on both sides of the change: two pieces, two letters, cut
        // where the splitter will cut.
        var t = VoiceTracker(settings: .standard)
        let x = axis(0), y = axis(1)
        let words = [
            TimedWord(text: "Standby", start: 0, end: 0.7), TimedWord(text: "LX", start: 0.7, end: 1.3),
            TimedWord(text: "Standing", start: 1.6, end: 2.2), TimedWord(text: "by", start: 2.2, end: 2.8),
        ]
        let pieces = t.assign(line([x, x, x, y, y, y], from: 0), lineStart: 0, lineEnd: 3, words: words)
        #expect(letters(pieces) == ["A", "B"])
        #expect(pieces.map(\.start) == [0, 1.5])
    }
}
