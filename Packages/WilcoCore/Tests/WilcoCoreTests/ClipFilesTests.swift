import Foundation
import Testing
@testable import WilcoCore

@Suite struct ClipFilesTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func transcript(_ stamp: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("Session \(stamp).jsonl")
        let line = try TranscriptFile.line(for: TranscriptSegment(channelID: UUID(), text: "Go.", timestamp: .now, sessionOffset: 1, isFinal: true))
        try line.write(to: url)
        return url
    }

    private func clip() -> ClipRecord {
        ClipRecord(channel: UUID(), kind: .unclear, sessionOffset: 3, duration: 2, engine: "apple")
    }

    @Test func clipsFolderSitsBesideTheTranscript() {
        let transcript = URL(filePath: "/tmp/x/Session 2026-11-21 1720-04.jsonl")
        let folder = ClipsFolder.url(forTranscript: transcript)
        #expect(folder.lastPathComponent == "Session 2026-11-21 1720-04.clips")
        #expect(folder.deletingLastPathComponent() == transcript.deletingLastPathComponent())
    }

    @Test func manifestAndLabelsRoundTrip() throws {
        let dir = try folder()
        let c = clip()
        let manifest = ClipManifest(clips: [c], dropped: 2)
        let labels = ClipLabels(voters: ["a": "b"], clips: [ClipLabel(clip: c.id, words: .agreed, text: "t", candidates: ["a": "t"], voice: .agreed, speaker: 1)], finished: true)
        try ClipsFolder.save(manifest, in: dir)
        try ClipsFolder.save(labels, in: dir)
        #expect(ClipsFolder.loadManifest(in: dir) == manifest)
        #expect(ClipsFolder.loadLabels(in: dir) == labels)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clips.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("labels.json").path))
        let json = #"{"clip":"\#(c.id.uuidString)","words":"disputed","candidates":{},"checked":"x"}"#
        let label = try WilcoJSON.decoder().decode(ClipLabel.self, from: Data(json.utf8))
        #expect(label.answer == "x")
    }

    @Test func olderLabelsWithoutVoiceErrorDecode() throws {
        let json = #"{"version":1,"voters":{"a":"1"},"clips":[],"finished":true}"#
        let labels = try WilcoJSON.decoder().decode(ClipLabels.self, from: Data(json.utf8))
        #expect(labels.voiceError == nil)
        #expect(labels.finished)
        var withError = labels
        withError.voiceError = "failed"
        let data = try WilcoJSON.encoder().encode(withError)
        #expect(try WilcoJSON.decoder().decode(ClipLabels.self, from: data) == withError)
    }

    @Test func wavRoundTripsWithinOneStep() throws {
        let input: [Float] = [0, 0.5, -0.5, 1, -1, 2]
        let data = WAV.encode(input)
        #expect(Array(data.prefix(4)) == Array("RIFF".utf8))
        #expect(Array(data[8 ..< 12]) == Array("WAVE".utf8))
        let out = try WAV.decode(data)
        #expect(out.sampleRate == 16_000)
        #expect(out.samples.count == 6)
        for (a, b) in zip(input, out.samples) {
            #expect(abs(max(-1, min(1, a)) - b) <= 1 / 32767)
        }
    }

    @Test func wavRejectsJunk() {
        #expect(throws: (any Error).self) { try WAV.decode(Data("hello".utf8)) }
    }

    @Test func needingLabelsSkipsOrphansFinishedAndEmpty() throws {
        let dir = try folder()
        let voters = ["apple": "1"]
        let withClip = ClipManifest(clips: [clip()])
        let a = try transcript("2026-11-21 1000-00", in: dir)
        try ClipsFolder.save(withClip, in: ClipsFolder.url(forTranscript: a))
        let b = try transcript("2026-11-21 1100-00", in: dir)
        try ClipsFolder.save(withClip, in: ClipsFolder.url(forTranscript: b))
        try ClipsFolder.save(ClipLabels(voters: voters, finished: true), in: ClipsFolder.url(forTranscript: b))
        try ClipsFolder.save(withClip, in: dir.appendingPathComponent("Session 2026-11-21 1200-00.clips"))
        let d = try transcript("2026-11-21 1300-00", in: dir)
        try ClipsFolder.save(withClip, in: ClipsFolder.url(forTranscript: d))
        try ClipsFolder.save(ClipLabels(voters: ["apple": "2"], finished: true), in: ClipsFolder.url(forTranscript: d))
        let e = try transcript("2026-11-21 1400-00", in: dir)
        try ClipsFolder.save(ClipManifest(), in: ClipsFolder.url(forTranscript: e))
        let result = ClipsFolder.needingLabels(in: dir, voters: voters)
        #expect(result.map(\.lastPathComponent) == [a, d].map(\.lastPathComponent))
    }

    @Test func deleteAllRemovesOnlyClipsFolders() throws {
        let dir = try folder()
        let a = try transcript("2026-11-21 1000-00", in: dir)
        let diagnostics = DiagnosticsFile.url(forTranscript: a)
        try Data("x".utf8).write(to: diagnostics)
        let clips = ClipsFolder.url(forTranscript: a)
        let c = clip()
        try ClipsFolder.save(ClipManifest(clips: [c]), in: clips)
        try WAV.encode([0, 0.1]).write(to: ClipsFolder.audioURL(for: c.id, in: clips))
        #expect(ClipsFolder.totalSize(in: dir) > 0)
        try ClipsFolder.deleteAll(in: dir)
        #expect(ClipsFolder.totalSize(in: dir) == 0)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: diagnostics.path))
        #expect(!FileManager.default.fileExists(atPath: clips.path))
    }

    @Test func sessionsListIgnoresClipsFolders() throws {
        let dir = try folder()
        let a = try transcript("2026-11-21 1000-00", in: dir)
        try ClipsFolder.save(ClipManifest(clips: [clip()]), in: ClipsFolder.url(forTranscript: a))
        #expect(try SessionHistory.summaries(in: dir, candidates: []).count == 1)
    }
}
