import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

/// Counts calls across tasks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = (0, 0)
    func set(_ done: Int, _ total: Int) { lock.withLock { stored = (done, total) } }
    var value: (Int, Int) { lock.withLock { stored } }
}

/// A voter that answers by the clip's first sample, which each test sets to
/// a tenth of the clip's index (samples are clamped to ±1) so the voter
/// knows which clip it hears.
private struct FakeVoter: ClipVoter {
    var id: String
    var version = "1"
    /// Text per clip index; a missing index throws.
    var texts: [Int: String]
    var delay: Duration = .zero
    var calls = Counter()

    func isInstalled() -> Bool { true }

    func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String {
        calls.add()
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let text = texts[Int(((samples.first ?? -1) * 10).rounded())] else { throw SayClipError(message: "no text") }
        return text
    }
}

/// A diarizer that names the speaker covering each clip, by clip position on the
/// joined recording.
private struct FakeDiarizer: ClipDiarizer {
    var id: String
    /// Speaker per clip, in the order the clips are joined.
    var speakers: [String]
    var durations: [Double]

    func isInstalled() -> Bool { true }

    func spans(of samples: [Float]) async throws -> [SpeakerSpan] {
        zip(VoiceAgreement.layout(durations: durations), speakers).map {
            SpeakerSpan(speaker: $1, start: $0.lowerBound, end: $0.upperBound)
        }
    }
}

private struct Session {
    let folder: URL
    let transcript: URL
    var records: [ClipRecord] = []

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "labeller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transcript = root.appending(path: "Session 2026-11-23 2000-00.jsonl")
        try Data().write(to: transcript)
        folder = ClipsFolder.url(forTranscript: transcript)
    }

    /// Adds a clip whose audio is one second whose first sample is `index` / 10.
    @discardableResult
    mutating func addClip(
        _ index: Int, channel: UUID = Session.channel, engine: String = SpeechEngine.parakeet.rawValue,
        writeAudio: Bool = true, sampleRate: Int = 16_000
    ) throws -> ClipRecord {
        let record = ClipRecord(channel: channel, kind: .unclear, sessionOffset: Double(index), duration: 1, engine: engine)
        records.append(record)
        try ClipsFolder.save(ClipManifest(clips: records), in: folder)
        if writeAudio {
            var samples = [Float](repeating: 0, count: sampleRate)
            samples[0] = Float(index) / 10
            try WAV.encode(samples, sampleRate: sampleRate).write(to: ClipsFolder.audioURL(for: record.id, in: folder))
        }
        return record
    }

    static let channel = UUID()

    var labels: ClipLabels? { ClipsFolder.loadLabels(in: folder) }
}

private struct FailingDiarizer: ClipDiarizer {
    var id = "broken"
    func isInstalled() -> Bool { true }
    func spans(of samples: [Float]) async throws -> [SpeakerSpan] {
        throw SayClipError(message: "model broke")
    }
}

/// A diarizer that cancels the task running it, then waits to be cancelled.
private struct CancellingDiarizer: ClipDiarizer {
    var id = "cancelling"
    func isInstalled() -> Bool { true }
    func spans(of samples: [Float]) async throws -> [SpeakerSpan] {
        withUnsafeCurrentTask { $0?.cancel() }
        try await Task.sleep(for: .seconds(10))
        return []
    }
}

@Suite("Clip labeller")
struct ClipLabellerTests {
    @Test func labelsAgreedAndDisputedClips() async throws {
        var session = try Session()
        let first = try session.addClip(1)
        let second = try session.addClip(2)
        let a = FakeVoter(id: "a", texts: [1: "Standby cue one", 2: "Go cue two"])
        let b = FakeVoter(id: "b", version: "2", texts: [1: "standby cue one", 2: "Go cue three"])
        let labeller = ClipLabeller(voters: [a, b], diarizers: [])
        #expect(labeller.voterVersions == ["a": "1", "b": "2"])

        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }

        let labels = try #require(session.labels)
        #expect(labels.finished)
        #expect(labels.voters == ["a": "1", "b": "2"])
        #expect(labels.clips.map(\.clip) == [first.id, second.id])
        #expect(labels.clips[0].words == .agreed)
        #expect(labels.clips[0].text == "Standby cue one")
        #expect(labels.clips[1].words == .disputed)
        #expect(labels.clips[1].text == nil)
        #expect(labels.clips[1].candidates == ["a": "Go cue two", "b": "Go cue three"])
        #expect(labels.clips.allSatisfy { $0.voice == nil })
    }

    @Test func labellerStopsWhenCancelledAndResumes() async throws {
        var session = try Session()
        for index in 1...5 { try session.addClip(index) }
        let texts = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, "Cue \($0)") })
        let a = FakeVoter(id: "a", texts: texts, delay: .milliseconds(50))
        let b = FakeVoter(id: "b", texts: texts, delay: .milliseconds(50))
        let labeller = ClipLabeller(voters: [a, b], diarizers: [])
        let progressCalls = Counter()
        let transcript = session.transcript

        let run = Task {
            try await labeller.label(transcript: transcript, show: nil) { _, _ in
                progressCalls.add()
                // Cancels the labelling task, which calls this.
                if progressCalls.count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await run.value }

        let stopped = try #require(session.labels)
        #expect(!stopped.finished)
        #expect((2...3).contains(stopped.clips.count))
        #expect(stopped.clips.allSatisfy { $0.words == .agreed })

        let before = a.calls.count
        let last = LastProgress()
        try await labeller.label(transcript: transcript, show: nil) { done, total in last.set(done, total) }
        #expect(a.calls.count - before == 5 - stopped.clips.count)
        #expect(last.value.0 == 5 && last.value.1 == 5)
        let finished = try #require(session.labels)
        #expect(finished.finished)
        #expect(finished.clips.map(\.clip) == session.records.map(\.id))
        #expect(finished.clips.allSatisfy { $0.words == .agreed })
    }

    @Test func labellerIgnoresStrayFilesAndMissingAudio() async throws {
        var session = try Session()
        let good = try session.addClip(1)
        try session.addClip(2, writeAudio: false)
        try session.addClip(3, sampleRate: 48_000)
        try WAV.encode([Float](repeating: 0, count: 16_000)).write(to: session.folder.appending(path: "x.wav"))
        let texts = [1: "Cue one", 2: "Cue two", 3: "Cue three", 0: "Stray"]
        let a = FakeVoter(id: "a", texts: texts)
        let labeller = ClipLabeller(voters: [a, FakeVoter(id: "b", texts: texts)], diarizers: [])

        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }

        let labels = try #require(session.labels)
        #expect(labels.clips.map(\.clip) == [good.id])
        #expect(labels.clips.first?.words == .agreed)
        #expect(a.calls.count == 1)
        #expect(labels.finished)
    }

    @Test func newVotersRelabelButKeepChecked() async throws {
        var session = try Session()
        let checked = try session.addClip(1)
        let other = try session.addClip(2)
        let gone = UUID()
        try ClipsFolder.save(
            ClipLabels(
                voters: ["a": "1"],
                clips: [
                    ClipLabel(clip: checked.id, words: .disputed, candidates: ["a": "old"], checked: "x"),
                    ClipLabel(clip: other.id, words: .notEnoughVoters, candidates: ["a": "old"]),
                    ClipLabel(clip: gone, words: .notEnoughVoters),
                ],
                finished: true
            ),
            in: session.folder
        )
        let texts = [1: "Cue one", 2: "Cue two"]
        let a = FakeVoter(id: "a", texts: texts)
        let b = FakeVoter(id: "b", texts: texts)

        try await ClipLabeller(voters: [a, b], diarizers: []).label(transcript: session.transcript, show: nil) { _, _ in }

        let labels = try #require(session.labels)
        #expect(labels.voters == ["a": "1", "b": "1"])
        #expect(labels.clips.map(\.clip) == [checked.id, other.id])
        #expect(labels.clips[0].checked == "x")
        #expect(labels.clips[0].candidates == ["a": "old"])
        #expect(labels.clips[1].words == .agreed)
        #expect(labels.clips[1].text == "Cue two")
        #expect(a.calls.count == 1)
        #expect(labels.finished)
    }

    @Test func sameVotersKeepFinishedLabels() async throws {
        var session = try Session()
        try session.addClip(1)
        let texts = [1: "Cue one"]
        let a = FakeVoter(id: "a", texts: texts)
        let labeller = ClipLabeller(voters: [a, FakeVoter(id: "b", texts: texts)], diarizers: [])
        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }
        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }
        #expect(a.calls.count == 1)
        #expect(session.labels?.finished == true)
    }

    @Test func failingVotersNeverCrash() async throws {
        var session = try Session()
        try session.addClip(1)
        let labeller = ClipLabeller(voters: [FakeVoter(id: "a", texts: [:]), FakeVoter(id: "b", texts: [1: "Cue"])], diarizers: [])
        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }
        let label = try #require(session.labels?.clips.first)
        #expect(label.words == .notEnoughVoters)
        #expect(label.candidates == ["b": "Cue"])
    }

    @Test func voterSittingOutDoesNotTranscribe() async throws {
        var session = try Session()
        try session.addClip(1, engine: SpeechEngine.longForm.rawValue)
        let apple = FakeVoter(id: ClipVoterID.appleLongForm, texts: [1: "Cue"])
        let labeller = ClipLabeller(voters: [apple, FakeVoter(id: "b", texts: [1: "Cue"])], diarizers: [])
        try await labeller.label(transcript: session.transcript, show: nil) { _, _ in }
        #expect(apple.calls.count == 0)
        #expect(session.labels?.clips.first?.words == .notEnoughVoters)
    }

    @Test func voicesNeedThreeClipsAndTwoDiarizers() async throws {
        var session = try Session()
        for index in 1...3 { try session.addClip(index) }
        let texts = [1: "One", 2: "Two", 3: "Three"]
        let voters = [FakeVoter(id: "a", texts: texts), FakeVoter(id: "b", texts: texts)]
        let durations = [1.0, 1.0, 1.0]
        let first = FakeDiarizer(id: "p", speakers: ["x", "x", "y"], durations: durations)
        let second = FakeDiarizer(id: "s", speakers: ["2", "2", "7"], durations: durations)

        try await ClipLabeller(voters: voters, diarizers: [first, second])
            .label(transcript: session.transcript, show: nil) { _, _ in }
        let labels = try #require(session.labels)
        #expect(labels.clips.map(\.speaker) == [0, 0, 1])
        #expect(labels.clips.allSatisfy { $0.voice == .agreed })

        var lone = try Session()
        for index in 1...3 { try lone.addClip(index) }
        try await ClipLabeller(voters: voters, diarizers: [first])
            .label(transcript: lone.transcript, show: nil) { _, _ in }
        let loneLabels = try #require(lone.labels)
        #expect(loneLabels.clips.allSatisfy { $0.voice == nil && $0.speaker == nil })
        #expect(loneLabels.finished)
    }

    @Test func voicesDisputedWhenDiarizersDisagree() async throws {
        var session = try Session()
        for index in 1...3 { try session.addClip(index) }
        let texts = [1: "One", 2: "Two", 3: "Three"]
        let voters = [FakeVoter(id: "a", texts: texts), FakeVoter(id: "b", texts: texts)]
        let durations = [1.0, 1.0, 1.0]
        let first = FakeDiarizer(id: "p", speakers: ["x", "x", "y"], durations: durations)
        let second = FakeDiarizer(id: "s", speakers: ["2", "7", "7"], durations: durations)

        try await ClipLabeller(voters: voters, diarizers: [first, second])
            .label(transcript: session.transcript, show: nil) { _, _ in }
        let labels = try #require(session.labels)
        #expect(labels.clips.map(\.voice) == [.agreed, .disputed, .agreed])
        #expect(labels.clips.map(\.speaker) == [0, nil, 1])
    }

    @Test func failingDiarizerRecordsErrorAndFinishes() async throws {
        var session = try Session()
        for index in 1...3 { try session.addClip(index) }
        let texts = [1: "One", 2: "Two", 3: "Three"]
        let voters = [FakeVoter(id: "a", texts: texts), FakeVoter(id: "b", texts: texts)]
        let good = FakeDiarizer(id: "p", speakers: ["x", "x", "y"], durations: [1, 1, 1])

        try await ClipLabeller(voters: voters, diarizers: [good, FailingDiarizer()])
            .label(transcript: session.transcript, show: nil) { _, _ in }
        let labels = try #require(session.labels)
        #expect(labels.finished)
        #expect(labels.clips.allSatisfy { $0.voice == nil && $0.speaker == nil })
        #expect(labels.voiceError?.isEmpty == false)
        #expect(labels.clips.allSatisfy { $0.words == .agreed })
    }

    @Test func cancelDuringVoicesSavesUnfinished() async throws {
        var session = try Session()
        for index in 1...3 { try session.addClip(index) }
        let texts = [1: "One", 2: "Two", 3: "Three"]
        let voters = [FakeVoter(id: "a", texts: texts), FakeVoter(id: "b", texts: texts)]
        let good = FakeDiarizer(id: "p", speakers: ["x", "x", "y"], durations: [1, 1, 1])
        let labeller = ClipLabeller(voters: voters, diarizers: [good, CancellingDiarizer()])
        let transcript = session.transcript

        let run = Task { try await labeller.label(transcript: transcript, show: nil) { _, _ in } }
        await #expect(throws: CancellationError.self) { try await run.value }
        let labels = try #require(session.labels)
        #expect(!labels.finished)
        #expect(labels.voiceError == nil)
        #expect(labels.clips.count == 3)
        #expect(labels.clips.allSatisfy { $0.words == .agreed && $0.voice == nil })
    }

    @Test func votersNotCalledAfterCancel() async throws {
        var session = try Session()
        try session.addClip(1)
        /// Cancels the task running it, as capture starting would.
        struct CancellingVoter: ClipVoter {
            var id = "a"
            var version = "1"
            func isInstalled() -> Bool { true }
            func transcribe(_ samples: [Float], vocabulary: [String], localeIdentifier: String) async throws -> String {
                withUnsafeCurrentTask { $0?.cancel() }
                return "Cue"
            }
        }
        let b = FakeVoter(id: "b", texts: [1: "Cue"])
        let c = FakeVoter(id: "c", texts: [1: "Cue"])
        let labeller = ClipLabeller(voters: [CancellingVoter(), b, c], diarizers: [])
        let transcript = session.transcript

        let run = Task { try await labeller.label(transcript: transcript, show: nil) { _, _ in } }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(b.calls.count == 0)
        #expect(c.calls.count == 0)
        let labels = try #require(session.labels)
        #expect(labels.clips.isEmpty)
        #expect(!labels.finished)
    }

    /// Three spoken calls labelled by the voters installed on this Mac.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func labelsASayMadeSession() async throws {
        let session = try Session()
        var records: [ClipRecord] = []
        let calls = ["Standby lighting cue forty two", "Sound cue seven go", "Fly cue twelve standby"]
        for (index, call) in calls.enumerated() {
            let samples = try sayClip(call)
            let record = ClipRecord(
                channel: Session.channel, kind: .unclear, sessionOffset: Double(index * 5),
                duration: Double(samples.count) / 16_000, engine: SpeechEngine.parakeet.rawValue
            )
            records.append(record)
            try FileManager.default.createDirectory(at: session.folder, withIntermediateDirectories: true)
            try WAV.encode(samples).write(to: ClipsFolder.audioURL(for: record.id, in: session.folder))
        }
        try ClipsFolder.save(ClipManifest(clips: records), in: session.folder)

        let ultra = ParakeetModelStore(
            directory: DataLocations.parakeetUltraModels, version: .ultra,
            vocabularyDirectory: DataLocations.parakeetModels
        )
        let voters = await ClipVoters.installed(ultra: ultra, whisper: WhisperModelStore())
        let diarizers: [any ClipDiarizer] = [PipelineClipDiarizer(), SortformerClipDiarizer()].filter { $0.isInstalled() }
        print("labeller voters: \(voters.map(\.id)), diarizers: \(diarizers.map(\.id))")

        try await ClipLabeller(voters: voters, diarizers: diarizers)
            .label(transcript: session.transcript, show: nil) { done, total in print("labelled \(done)/\(total)") }

        let labels = try #require(session.labels)
        print("labeller verdicts: \(labels.clips.map(\.words.rawValue)), voices: \(labels.clips.map { $0.voice?.rawValue ?? "-" })")
        #expect(labels.finished)
        #expect(labels.clips.count == 3)
        if voters.count >= 2 {
            #expect(labels.clips.filter { $0.words == .agreed }.count >= 2)
        } else {
            #expect(labels.clips.allSatisfy { $0.words == .notEnoughVoters })
        }
    }
}
