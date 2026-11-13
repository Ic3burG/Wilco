import FluidAudio
import Foundation
import Testing
@testable import WilcoTranscription

@Suite struct ParakeetTests {
    @Test func languageHintFromChannelIdentifier() {
        #expect(ParakeetLanguages.language(for: "") == nil)
        #expect(ParakeetLanguages.language(for: "en_US") == .english)
        #expect(ParakeetLanguages.language(for: "fr-CA") == .french)
        #expect(ParakeetLanguages.language(for: "ja_JP") == nil)
    }

    @Test func missingModelFailsTheChannelNotTheApp() async {
        let store = ParakeetModelStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(!store.isInstalled())
        await #expect(throws: ParakeetError.notInstalled) { _ = try await store.manager() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func transcribesASpokenCall() async throws {
        let samples = try sayClip("Standby lighting cue forty two")
        // Use the app's model when installed; otherwise FluidAudio's default
        // cache, which holds the same files, to avoid a fresh download.
        var store = ParakeetModelStore()
        if !store.isInstalled() {
            store = ParakeetModelStore(directory: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
        }
        let recognition = try await ParakeetRecognizer(store: store, language: .english).recognize(samples)
        #expect(recognition?.text.lowercased().contains("lighting") == true)
    }
}
