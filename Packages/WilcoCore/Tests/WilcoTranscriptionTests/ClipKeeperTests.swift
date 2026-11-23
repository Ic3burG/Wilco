import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite struct ClipKeeperTests {
    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Session.clips")
    }

    private func offer(
        channel: UUID = UUID(), at offset: Double, duration: Double = 1, confidence: Double?,
        samples: Int = 16_000
    ) -> ClipOffer {
        ClipOffer(
            candidate: ClipCandidate(channel: channel, sessionOffset: offset, duration: duration, confidence: confidence),
            engine: "parakeet", whisperModel: nil,
            samples: (0..<samples).map { Float($0 % 100) / 200 })
    }

    private func wavFiles(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "wav" }
    }

    @Test func keepsAndWritesUnclearClips() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, saveInterval: nil)
        let line = offer(at: 12.5, confidence: nil)
        keeper.tap.offer(line)
        await keeper.finish()

        let manifest = try #require(ClipsFolder.loadManifest(in: folder))
        #expect(manifest.clips.count == 1)
        let record = try #require(manifest.clips.first)
        #expect(record.id == line.candidate.id)
        #expect(record.kind == .unclear)
        #expect(record.engine == "parakeet")
        #expect(record.whisperModel == nil)
        #expect(record.channel == line.candidate.channel)
        #expect(record.sessionOffset == 12.5)
        #expect(record.duration == 1)
        #expect(record.confidence == nil)
        let data = try Data(contentsOf: ClipsFolder.audioURL(for: record.id, in: folder))
        #expect(try WAV.decode(data).samples.count == 16_000)
        #expect(await keeper.manifest == manifest)
    }

    @Test func replacedClipsAreDeleted() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(
            folder: folder, selector: ClipSelector(unclearCap: 1, random: { _ in 0 }), saveInterval: nil)
        let first = offer(at: 0, confidence: nil)
        let second = offer(at: 30, confidence: nil)
        keeper.tap.offer(first)
        keeper.tap.offer(second)
        await keeper.finish()

        let files = wavFiles(in: folder)
        #expect(files.count == 1)
        #expect(files.first?.lastPathComponent == "\(second.candidate.id.uuidString).wav")
        let manifest = try #require(ClipsFolder.loadManifest(in: folder))
        #expect(manifest.clips.map(\.id) == [second.candidate.id])
    }

    @Test func exchangesAreWrittenWhenTheRunCloses() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, saveInterval: nil)
        let channel = UUID()
        let lines = (0..<3).map { offer(channel: channel, at: Double($0) * 2, confidence: 0.95) }
        for line in lines { keeper.tap.offer(line) }
        await keeper.finish()

        let manifest = try #require(ClipsFolder.loadManifest(in: folder))
        #expect(manifest.clips.count == 3)
        #expect(manifest.clips.allSatisfy { $0.exchange == 1 && $0.kind == .exchange })
        #expect(Set(manifest.clips.map(\.id)) == Set(lines.map(\.candidate.id)))
        #expect(wavFiles(in: folder).count == 3)
    }

    @Test func anUnclearLineLaterInAnExchangeIsUpdatedNotDuplicated() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, saveInterval: nil)
        let channel = UUID()
        let lines = [
            offer(channel: channel, at: 0, confidence: 0.3),
            offer(channel: channel, at: 2, confidence: 0.95),
            offer(channel: channel, at: 4, confidence: 0.95),
        ]
        for line in lines { keeper.tap.offer(line) }
        await keeper.finish()

        let manifest = try #require(ClipsFolder.loadManifest(in: folder))
        #expect(manifest.clips.count == 3)
        #expect(manifest.clips.allSatisfy { $0.kind == .exchange && $0.exchange == 1 })
        #expect(wavFiles(in: folder).count == 3)
    }

    @Test func dropsWhenTheQueueIsFull() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, queueLimit: 2, saveInterval: nil)
        // Separate channels, all unclear: the selector keeps every one it sees.
        let lines = (0..<10).map { offer(at: Double($0), confidence: nil) }
        offerAll(lines, to: keeper.tap)
        await keeper.finish()

        let manifest = try #require(ClipsFolder.loadManifest(in: folder))
        #expect(manifest.dropped >= 1)
        #expect(manifest.clips.count + manifest.dropped == 10)
        #expect(wavFiles(in: folder).count == manifest.clips.count)
    }

    @Test(.timeLimit(.minutes(1))) func keeperSurvivesAnUnwritableFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        let folder = file.appendingPathComponent("Session.clips")

        let keeper = ClipKeeper(folder: folder, saveInterval: nil)
        for i in 0..<5 { keeper.tap.offer(offer(at: Double(i) * 30, confidence: nil)) }
        await keeper.finish()
        #expect(ClipsFolder.loadManifest(in: folder) == nil)
    }

    @Test func savesPeriodicallyWhileRunning() async throws {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, saveInterval: 0.05)
        keeper.tap.offer(offer(at: 0, confidence: nil))
        var manifest: ClipManifest?
        for _ in 0..<200 {
            manifest = ClipsFolder.loadManifest(in: folder)
            if manifest != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manifest?.clips.count == 1)
        await keeper.finish()
    }

    @Test func aSessionWithNothingKeptMakesNoFolder() async {
        let folder = tempFolder()
        let keeper = ClipKeeper(folder: folder, saveInterval: nil)
        keeper.tap.offer(offer(at: 0, duration: 0.2, confidence: nil))
        await keeper.finish()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

/// Offers from a plain synchronous context, as a transcriber's pump would, so
/// the keeper gets no chance to drain between offers.
private func offerAll(_ lines: [ClipOffer], to tap: ClipTap) {
    for line in lines { tap.offer(line) }
}
