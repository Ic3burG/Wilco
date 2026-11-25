import Testing
@testable import WilcoCore

@Suite("Long-form languages no longer needed")
struct UnusedLanguageTests {
    @Test func theLearningLanguageIsNeverOfferedForRemoval() {
        #expect(SpeechModelNeeds.unusedLongFormLocales(reserved: ["en-US"], channels: [], alsoNeeded: ["en-US"]).isEmpty)
    }

    @Test func spellingsOfTheSameLanguageMatch() {
        let channel = ChannelConfig(name: "SM", localeIdentifier: "fr_FR", engine: .longForm)
        #expect(SpeechModelNeeds.unusedLongFormLocales(reserved: ["fr-FR"], channels: [channel], alsoNeeded: []).isEmpty)
    }

    @Test func aLanguageNothingNeedsIsOffered() {
        let channel = ChannelConfig(name: "SM", localeIdentifier: "fr_FR", engine: .parakeet)
        #expect(SpeechModelNeeds.unusedLongFormLocales(reserved: ["fr-FR", "en-US"], channels: [channel], alsoNeeded: ["en-US"])
            == ["fr-FR"])
    }
}
