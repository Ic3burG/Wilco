import Testing
@testable import WilcoCore

@Suite("Transcript normalizer")
struct TranscriptNormalizerTests {
    @Test func lowercasesAndDropsPunctuation() {
        #expect(TranscriptNormalizer.words("Standby, Lighting!") == ["standby", "lighting"])
    }

    @Test func spellsOutNumbers() {
        #expect(TranscriptNormalizer.words("cue 42") == ["cue", "forty", "two"])
        #expect(TranscriptNormalizer.words("cue forty-two") == ["cue", "forty", "two"])
        #expect(TranscriptNormalizer.words("cue 105") == ["cue", "one", "hundred", "five"])
        #expect(TranscriptNormalizer.words("0") == ["zero"])
    }

    @Test func readsCueShorthand() {
        #expect(TranscriptNormalizer.words("Q5 go") == ["cue", "five", "go"])
        #expect(TranscriptNormalizer.words("queue 5") == ["cue", "five"])
    }

    @Test func joinsStandBy() {
        #expect(TranscriptNormalizer.words("stand by sound") == ["standby", "sound"])
        #expect(TranscriptNormalizer.words("Stand-by") == ["standby"])
    }

    @Test func treatsOKAsOkay() {
        #expect(TranscriptNormalizer.words("OK, thanks") == ["okay", "thanks"])
    }
}

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        let errors = WordErrorRate.compare(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"])
        #expect(errors.errors == 0)
        #expect(errors.rate == 0)
    }

    @Test func countsEachKindOfError() {
        // "a b c d" -> "a x c d e": one substitution, one insertion.
        let errors = WordErrorRate.compare(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c", "d", "e"])
        #expect(errors == WordErrors(substitutions: 1, deletions: 0, insertions: 1, referenceWords: 4))
        #expect(errors.rate == 0.5)
    }

    @Test func missingWordsAreDeletions() {
        let errors = WordErrorRate.compare(reference: ["a", "b"], hypothesis: [])
        #expect(errors == WordErrors(substitutions: 0, deletions: 2, insertions: 0, referenceWords: 2))
    }

    @Test func errorsAddUpAcrossChannels() {
        let total = [
            WordErrors(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 4),
            WordErrors(substitutions: 0, deletions: 1, insertions: 0, referenceWords: 6),
        ].reduce(WordErrors(), +)
        #expect(total.rate == 0.2)
    }
}
