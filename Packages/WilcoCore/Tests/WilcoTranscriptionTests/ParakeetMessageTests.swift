import Testing
@testable import WilcoTranscription

@Suite("Parakeet messages name the page that installs it")
struct ParakeetMessageTests {
    @Test func missingModelsPointAtSpeechModels() {
        for error in [ParakeetError.notInstalled, .vocabularyNotInstalled] {
            let text = error.errorDescription ?? ""
            #expect(text.contains("Settings › Speech Models"))
            #expect(!text.contains("Languages"))
        }
    }
}
