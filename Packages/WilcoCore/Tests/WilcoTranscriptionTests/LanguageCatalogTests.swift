import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Language catalog")
struct LanguageCatalogTests {
    @Test func whisperOffersAutoDetectFirstThenReadableNames() async {
        let options = await LanguageCatalog.options(for: .whisper)
        #expect(options.first == .autoDetect)
        #expect(options.contains { $0.id == "en" && $0.name.contains("English") })
    }

    @Test func whisperMatchesOnLanguageAlone() {
        #expect(LanguageCatalog.selection(for: "en_US", engine: .whisper, in: []) == "en")
        #expect(LanguageCatalog.selection(for: "", engine: .whisper, in: []) == "")
    }

    @Test func appleMatchesEitherIdentifierSpelling() {
        let options = [LanguageOption(id: "en-US", name: "English (United States)")]
        #expect(LanguageCatalog.selection(for: "en_US", engine: .longForm, in: options) == "en-US")
        #expect(LanguageCatalog.selection(for: "fr_FR", engine: .longForm, in: options) == "fr_FR")
    }

    @Test func namesAreReadable() {
        #expect(LanguageCatalog.displayName(for: "en_US") != "en_US")
        #expect(LanguageCatalog.displayName(for: "") == "Detect Automatically")
    }

    @Test func oldShowFilesDoNotTranslate() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Stage"}"#
        let channel = try JSONDecoder().decode(ChannelConfig.self, from: Data(json.utf8))
        #expect(channel.translateToEnglish == false)
    }

    @Test func missingModelHasNoSize() {
        let store = WhisperModelStore(downloadBase: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(store.sizeOnDisk(of: .tiny) == nil)
    }

    @Test func removingAWhisperModelDeletesOnlyItsFolder() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = WhisperModelStore(downloadBase: base)
        for model in [WhisperModel.tiny, .base] {
            try FileManager.default.createDirectory(at: store.folder(for: model), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: store.folder(for: model).appending(path: "config.json"))
        }
        #expect(store.sizeOnDisk(of: .tiny) != nil)

        try store.remove(.tiny)
        #expect(!store.isDownloaded(.tiny))
        #expect(store.isDownloaded(.base))
        try store.remove(.small)  // not there: nothing to do
    }

    @Test func whisperHasNoAppleAssets() async {
        #expect(await SpeechAssets.status(engine: .whisper, localeIdentifier: "en_US") == .unavailable)
    }
}

/// Asks macOS about its speech models, so it runs with the recognition tests.
@Suite("Speech assets", .enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] == "1"))
struct SpeechAssetTests {
    @Test func englishLongFormIsInstalledAfterTheRecognitionTests() async {
        guard #available(macOS 26, *) else { return }
        #expect(await SpeechAssets.status(engine: .longForm, localeIdentifier: "en_US") == .installed)
    }

    @Test func aMadeUpLanguageIsUnavailable() async {
        guard #available(macOS 26, *) else { return }
        #expect(await SpeechAssets.status(engine: .longForm, localeIdentifier: "xx_XX") == .unavailable)
    }
}
