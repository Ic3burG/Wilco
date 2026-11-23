import Testing
@testable import WilcoCore

@Suite("Voice agreement")
struct VoiceAgreementTests {
    @Test func layoutAddsGaps() {
        #expect(VoiceAgreement.layout(durations: [2, 3]) == [0...2, 3...6])
        #expect(VoiceAgreement.layout(durations: []) == [])
    }

    @Test func speakerCoveringMost() {
        let spans = [
            SpeakerSpan(speaker: "A", start: 0, end: 1.5),
            SpeakerSpan(speaker: "B", start: 1.5, end: 2.2),
        ]
        #expect(VoiceAgreement.speaker(of: 0...2, in: spans) == "A")
        #expect(VoiceAgreement.speaker(of: 10...11, in: spans) == nil)
    }

    @Test func speakerAddsUpEverySpanOfTheSameVoice() {
        // A has the longest single span, but B covers more in total.
        let spans = [
            SpeakerSpan(speaker: "A", start: 0, end: 0.8),
            SpeakerSpan(speaker: "B", start: 0.8, end: 1.4),
            SpeakerSpan(speaker: "B", start: 1.4, end: 2),
        ]
        #expect(VoiceAgreement.speaker(of: 0...2, in: spans) == "B")
    }

    @Test func agreeMatchesRenamedSpeakers() {
        #expect(VoiceAgreement.agree(["s1", "s1", "s2", "s2"], ["x", "x", "y", "y"]) == [0, 0, 1, 1])
    }

    @Test func disagreementIsNil() {
        #expect(VoiceAgreement.agree(["s1", "s1", "s2"], ["x", "x", "x"]) == [0, 0, nil])
    }

    @Test func missingSpeakerIsNil() {
        #expect(VoiceAgreement.agree(["s1", nil], ["x", "x"]) == [0, nil])
    }

    @Test func numbersFollowFirstAppearance() {
        #expect(VoiceAgreement.agree(["s9", "s2", "s9"], ["b", "a", "b"]) == [0, 1, 0])
    }

    @Test func numbersFollowAEvenWhenItsFirstClipDisagrees() {
        // s1 comes first in A, though its first clip doesn't agree.
        #expect(VoiceAgreement.agree(["s1", "s2", "s1", "s1"], ["z", "y", "x", "x"]) == [nil, 1, 0, 0])
    }

    @Test func aSplitVoiceKeepsOnlyItsBestMatch() {
        // B hears two voices where A hears one: only the larger part agrees.
        #expect(VoiceAgreement.agree(["s1", "s1", "s1"], ["x", "x", "y"]) == [0, 0, nil])
    }

    @Test func numbersSkipSpeakersThatNeverAgree() {
        #expect(VoiceAgreement.agree(["s1", "s2", "s3"], ["x", "x", "z"]) == [0, nil, 1])
    }

    @Test func mismatchedLengthsCompareTheSharedPart() {
        #expect(VoiceAgreement.agree(["s1", "s1", "s2"], ["x"]) == [0, nil, nil])
    }
}
