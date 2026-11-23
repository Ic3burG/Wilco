import Testing
@testable import WilcoCore

@Suite("Clip agreement")
struct ClipAgreementTests {
    let ultra = ClipVoterID.parakeetUltra
    let apple = ClipVoterID.appleLongForm
    let whisper = ClipVoterID.whisperLarge

    @Test func twoVotersMustBothMatch() {
        let result = ClipAgreement.words(
            candidates: [ultra: "Standby Tea Time, cue five.", apple: "standby tea time cue 5"],
            voters: [ultra, apple], sittingOut: []
        )
        #expect(result.verdict == .agreed)
        #expect(result.text == "Standby Tea Time, cue five.")
    }

    @Test func twoVotersDisagree() {
        let result = ClipAgreement.words(
            candidates: [ultra: "t time", apple: "tea time"], voters: [ultra, apple], sittingOut: []
        )
        #expect(result.verdict == .disputed)
        #expect(result.text == nil)
    }

    @Test func anyTwoOfThree() {
        let result = ClipAgreement.words(
            candidates: [ultra: "go", apple: "no", whisper: "go"], voters: [ultra, apple, whisper], sittingOut: []
        )
        #expect(result.verdict == .agreed)
        #expect(result.text == "go")
    }

    @Test func laterPairAgreeingKeepsTheFirstMatchingVotersText() {
        let result = ClipAgreement.words(
            candidates: [ultra: "no", apple: "Go.", whisper: "go"], voters: [ultra, apple, whisper], sittingOut: []
        )
        #expect(result.verdict == .agreed)
        #expect(result.text == "Go.")
    }

    @Test func liveEngineSitsOut() {
        #expect(ClipAgreement.sittingOut(engine: "whisper", whisperModel: "large") == [whisper])
        #expect(ClipAgreement.sittingOut(engine: "whisper", whisperModel: "small") == [])
        #expect(ClipAgreement.sittingOut(engine: "longForm", whisperModel: nil) == [apple])
        #expect(ClipAgreement.sittingOut(engine: "parakeet", whisperModel: nil) == [])
        let result = ClipAgreement.words(
            candidates: [ultra: "a", apple: "b", whisper: "a"], voters: [ultra, apple, whisper], sittingOut: [whisper]
        )
        #expect(result.verdict == .disputed)
        #expect(result.text == nil)
    }

    @Test func tooFewVoters() {
        let result = ClipAgreement.words(candidates: [ultra: "go"], voters: [ultra], sittingOut: [])
        #expect(result.verdict == .notEnoughVoters)
        #expect(result.text == nil)
        let sat = ClipAgreement.words(
            candidates: [ultra: "go", whisper: "go"], voters: [ultra, whisper], sittingOut: [whisper]
        )
        #expect(sat.verdict == .notEnoughVoters)
    }

    @Test func emptyTextsDontAgree() {
        let result = ClipAgreement.words(candidates: [ultra: "", apple: ""], voters: [ultra, apple], sittingOut: [])
        #expect(result.verdict == .disputed)
        #expect(result.text == nil)
    }
}
