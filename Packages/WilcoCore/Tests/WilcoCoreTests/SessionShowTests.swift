import Foundation
import Testing
@testable import WilcoCore

@Suite("Session show")
struct SessionShowTests {
    private let start = Date(timeIntervalSince1970: 1_794_100_000)

    private func line(_ channel: UUID) -> TranscriptSegment {
        TranscriptSegment(channelID: channel, text: "Go", timestamp: start, sessionOffset: 0, isFinal: true, confidence: 0.9)
    }

    private func show(_ name: String, channels: Int) -> ShowDocument {
        var show = ShowDocument(name: name)
        for _ in 0..<channels { _ = show.addChannel() }
        return show
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SessionShowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sitsBesideTheTranscript() {
        let transcript = URL(filePath: "/tmp/Transcripts/Session 2026-11-20 1449-33.jsonl")
        #expect(SessionShow.url(forTranscript: transcript).path == "/tmp/Transcripts/Session 2026-11-20 1449-33.wilco")
    }

    @Test func roundTrips() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "Session.jsonl")
        let saved = show("Dallas", channels: 2)
        try SessionShow.save(saved, forTranscript: transcript)
        #expect(SessionShow.load(forTranscript: transcript) == saved)
    }

    @Test func missingOrUnreadableCopyLoadsNothing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "Session.jsonl")
        #expect(SessionShow.load(forTranscript: transcript) == nil)
        try Data("not json".utf8).write(to: SessionShow.url(forTranscript: transcript))
        #expect(SessionShow.load(forTranscript: transcript) == nil)
    }

    @Test func picksTheShowSharingTheMostChannels() {
        let dallas = show("Dallas", channels: 3)
        var phoenix = dallas
        phoenix.name = "Phoenix"
        phoenix.channels.removeLast()  // a copy that lost one channel
        let spoke = dallas.channels.map(\.id)
        let best = SessionShow.bestMatch(for: spoke.map(line), among: [phoenix, dallas])
        #expect(best?.name == "Dallas")
    }

    @Test func aTieGoesToTheEarlierCandidate() {
        let dallas = show("Dallas", channels: 2)
        var phoenix = dallas
        phoenix.name = "Phoenix"
        let segments = [line(dallas.channels[0].id)]
        #expect(SessionShow.bestMatch(for: segments, among: [phoenix, dallas])?.name == "Phoenix")
        #expect(SessionShow.bestMatch(for: segments, among: [dallas, phoenix])?.name == "Dallas")
    }

    @Test func noSharedChannelsMatchesNothing() {
        let segments = [line(UUID())]
        #expect(SessionShow.bestMatch(for: segments, among: [show("Dallas", channels: 2)]) == nil)
    }

    @Test func writerSavesTheShowWithTheFirstLineAndOnFinish() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "Session.jsonl")
        var current = show("Dallas", channels: 1)
        let writer = TranscriptWriter(url: transcript, show: current)
        #expect(SessionShow.load(forTranscript: transcript) == nil)  // nobody has spoken yet

        try writer.append(line(current.channels[0].id))
        #expect(SessionShow.load(forTranscript: transcript)?.name == "Dallas")

        current.name = "Dallas Night 2"
        writer.finish(show: current)
        #expect(SessionShow.load(forTranscript: transcript)?.name == "Dallas Night 2")
    }

    @Test func finishingASilentSessionLeavesNoFiles() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "Session.jsonl")
        let writer = TranscriptWriter(url: transcript, show: show("Dallas", channels: 1))
        writer.finish(show: show("Dallas", channels: 1))
        #expect(!FileManager.default.fileExists(atPath: SessionShow.url(forTranscript: transcript).path))
    }
}
