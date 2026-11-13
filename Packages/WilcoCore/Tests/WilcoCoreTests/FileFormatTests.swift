import Foundation
import Testing
@testable import WilcoCore

/// Show and transcript files in format version 1 must keep opening. The
/// fixtures keep the exact JSON structure of real files with identifying text
/// replaced.
@Suite("File format compatibility")
struct FileFormatTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    @Test func decodesShowFile() throws {
        let show = try WilcoJSON.decoder().decode(ShowDocument.self, from: fixture("show-v1.wilco"))

        #expect(show.formatVersion == 1)
        #expect(show.name == "New Show")
        #expect(show.channels.count == 15)
        #expect(show.mcpPort == 8787)
        #expect(show.mosPort == 10540)
        #expect(show.whisperModel == WhisperModel.base.rawValue)

        let first = try #require(show.channels.first)
        #expect(first.id == UUID(uuidString: "39810948-EF13-449A-BD50-3B5A55BB058B"))
        #expect(first.tint == .blue)
        #expect(first.deviceChannel == 0)
        #expect(first.groupID == nil)
        #expect(first.engine == .longForm)
        #expect(first.latencyProfile == .leadAndCorrect)

        #expect(show.channels.contains { $0.engine == .whisper && $0.localeIdentifier == "en" })
    }

    @Test func showSurvivesRoundTrip() throws {
        let original = try WilcoJSON.decoder().decode(ShowDocument.self, from: fixture("show-v1.wilco"))
        let reencoded = try WilcoJSON.encoder().encode(original)
        #expect(try WilcoJSON.decoder().decode(ShowDocument.self, from: reencoded) == original)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let show = try WilcoJSON.decoder().decode(ShowDocument.self, from: Data(#"{"name":"Tour"}"#.utf8))
        #expect(show.name == "Tour")
        #expect(show.formatVersion == ShowDocument.currentFormatVersion)
        #expect(show.channels.isEmpty)
        #expect(show.mcpPort == 8787)
        #expect(show.mosID == "wilco")
    }

    @Test func decodesTranscriptAndSkipsTornLastLine() throws {
        let segments = TranscriptFile.segments(in: try fixture("session-v1.jsonl"))

        #expect(segments.count == 2)
        #expect(segments[0].text == "Standby lighting cue five.")
        #expect(segments[0].timestamp == Date(timeIntervalSince1970: 1_794_104_725))
        #expect(segments[1].confidence == 0.9087241379310345)
    }

    @Test func transcriptLineIsSingleLineISO8601() throws {
        let segment = TranscriptSegment(
            channelID: UUID(),
            text: "Go",
            timestamp: Date(timeIntervalSince1970: 1_794_104_725),
            sessionOffset: 1.5,
            isFinal: true
        )
        let line = String(decoding: try TranscriptFile.line(for: segment), as: UTF8.self)

        #expect(line.hasSuffix("}\n"))
        #expect(line.dropLast().contains("\n") == false)
        #expect(line.contains(#""timestamp":"2026-11-08T02:25:25Z""#))
    }

    @Test func sessionFileName() {
        let start = Date(timeIntervalSince1970: 1_794_104_751)
        let name = TranscriptFile.fileName(for: start, timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(name == "Session 2026-11-07 2025-51.jsonl")
    }

    /// Checks the user's own show when it is present. Skipped elsewhere, such as CI.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: FileFormatTests.liveShowPath)))
    func decodesLiveShowOnThisMac() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.liveShowPath))
        _ = try WilcoJSON.decoder().decode(ShowDocument.self, from: data)
    }

    static let liveShowPath = DataLocations.root.appending(path: ShowFile.currentName).path
}
