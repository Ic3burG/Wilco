import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Clip diarizers")
struct ClipDiarizerTests {
    private func emptyFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func missingModelsThrowNotInstalled() async {
        let diarizers: [any ClipDiarizer] = [
            PipelineClipDiarizer(directory: emptyFolder()),
            SortformerClipDiarizer(directory: emptyFolder()),
        ]
        for diarizer in diarizers {
            #expect(!diarizer.isInstalled())
            await #expect(throws: ClipDiarizerError.notInstalled) {
                _ = try await diarizer.spans(of: [Float](repeating: 0.1, count: 16_000))
            }
        }
        #expect(SortformerClipDiarizer(directory: emptyFolder()).sizeOnDisk() == nil)
    }

    @Test func idsDiffer() {
        #expect(PipelineClipDiarizer().id != SortformerClipDiarizer().id)
    }

    @Test func readsThePLDAVector() throws {
        let values: [Float] = [1.5, -2, 0.25]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let json = #"{"tensors": {"psi": {"data_base64": "\#(data.base64EncodedString())"}}}"#
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(json.utf8).write(to: file)
        #expect(try PipelineClipDiarizer.pldaPsi(from: file) == [1.5, -2, 0.25])

        try Data(#"{"tensors": {}}"#.utf8).write(to: file)
        #expect(throws: ClipDiarizerError.self) { try PipelineClipDiarizer.pldaPsi(from: file) }
    }

    /// `WILCO_SORTFORMER_MODELS` names a folder to download Sortformer into
    /// for these tests, so it can be tried without installing it for the app.
    private static let sortformerOverride = ProcessInfo.processInfo.environment["WILCO_SORTFORMER_MODELS"]
        .map { URL(fileURLWithPath: $0) }
    private static var sortformerFolder: URL { sortformerOverride ?? DataLocations.sortformerModels }
    private static var sortformerAvailable: Bool {
        sortformerOverride != nil || SortformerClipDiarizer(directory: sortformerFolder).isInstalled()
    }

    private func sortformer() async throws -> SortformerClipDiarizer {
        let diarizer = SortformerClipDiarizer(directory: Self.sortformerFolder)
        if !diarizer.isInstalled() { try await diarizer.install { _ in } }
        #expect(diarizer.isInstalled())
        #expect((diarizer.sizeOnDisk() ?? 0) > 100_000_000)
        return diarizer
    }

    private static let asrTests = ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil

    @Test(.enabled(if: asrTests && PipelineClipDiarizer().isInstalled()))
    func pipelineTellsTwoVoicesApart() async throws {
        try await tellsTwoVoicesApart(PipelineClipDiarizer())
    }

    @Test(.enabled(if: asrTests && sortformerAvailable))
    func sortformerTellsTwoVoicesApart() async throws {
        try await tellsTwoVoicesApart(sortformer())
    }

    @Test(.enabled(if: asrTests && PipelineClipDiarizer().isInstalled() && sortformerAvailable))
    func bothAgreeOnTwoVoices() async throws {
        let (clips, recording) = try twoVoiceRecording()
        let ranges = VoiceAgreement.layout(durations: clips.map { Double($0.count) / 16_000 })
        let a = try await PipelineClipDiarizer().spans(of: recording)
        let b = try await sortformer().spans(of: recording)
        let agreed = VoiceAgreement.agree(
            ranges.map { VoiceAgreement.speaker(of: $0, in: a) },
            ranges.map { VoiceAgreement.speaker(of: $0, in: b) }
        )
        print("Clip diarizers agree: \(agreed)")
        #expect(agreed == [0, 1, 0, 1, 0, 1])
    }

    /// Six clips, two system voices taking turns, joined with 1 s of silence.
    private func twoVoiceRecording() throws -> (clips: [[Float]], recording: [Float]) {
        let samantha = try sayVoice("Samantha")
        let daniel = try sayVoice("Daniel")
        let clips = try [
            sayClip("Standby lighting cue forty two and sound cue seventeen please", voice: samantha),
            sayClip("Lighting is standing by for cue forty two, thank you", voice: daniel),
            sayClip("Sound cue seventeen, are you standing by for that one", voice: samantha),
            sayClip("Yes, sound is standing by, ready when you are", voice: daniel),
            sayClip("Lighting cue forty two and sound cue seventeen, go", voice: samantha),
            sayClip("Gone, and that was a nice clean change, thank you", voice: daniel),
        ]
        let gap = [Float](repeating: 0, count: 16_000)
        let recording = Array(clips.map { $0 }.joined(separator: gap))
        return (clips, recording)
    }

    private func tellsTwoVoicesApart(_ diarizer: any ClipDiarizer) async throws {
        let (clips, recording) = try twoVoiceRecording()
        let ranges = VoiceAgreement.layout(durations: clips.map { Double($0.count) / 16_000 })
        let clock = ContinuousClock()
        var spans: [SpeakerSpan] = []
        let elapsed = try await clock.measure { spans = try await diarizer.spans(of: recording) }
        let speakers = ranges.map { VoiceAgreement.speaker(of: $0, in: spans) }
        print("\(diarizer.id): \(speakers) in \(elapsed) for \(Double(recording.count) / 16_000) s")
        #expect(spans.allSatisfy { $0.start < $0.end })
        #expect(speakers.allSatisfy { $0 != nil })
        #expect(speakers[0] == speakers[2] && speakers[2] == speakers[4])
        #expect(speakers[1] == speakers[3] && speakers[3] == speakers[5])
        #expect(speakers[0] != speakers[1])
    }
}
