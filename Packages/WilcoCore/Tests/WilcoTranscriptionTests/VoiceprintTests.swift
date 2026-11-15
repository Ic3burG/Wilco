import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Voiceprints")
struct VoiceprintTests {
    /// A store pointed at an empty folder, so nothing can load.
    private func emptyStore() -> WeSpeakerVoiceprints {
        WeSpeakerVoiceprints(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func shortAudioGivesNoPrints() async throws {
        let store = emptyStore()
        let prints = try await store.voiceprints(of: [Float](repeating: 0.1, count: 4_800), startingAt: 12)
        #expect(prints.isEmpty)
    }

    @Test func missingModelThrowsNotInstalled() async {
        let store = emptyStore()
        #expect(!store.isInstalled())
        await #expect(throws: VoiceprintError.notInstalled) {
            _ = try await store.voiceprints(of: [Float](repeating: 0.1, count: 16_000), startingAt: 0)
        }
    }

    @Test func windowsAreOnePointFiveSecondsEveryHalfSecond() {
        let rate = WeSpeakerVoiceprints.sampleRate
        // Under half a second: nothing.
        #expect(WeSpeakerVoiceprints.windows(sampleCount: rate / 2 - 1).isEmpty)
        // Half a second to a window's length: one window over all of it.
        #expect(WeSpeakerVoiceprints.windows(sampleCount: rate) == [0..<rate])
        #expect(WeSpeakerVoiceprints.windows(sampleCount: rate * 3 / 2) == [0..<(rate * 3 / 2)])
        // 2.5 s: windows at 0, 0.5 and 1.0 s, each 1.5 s long.
        let half = rate / 2
        let length = rate * 3 / 2
        #expect(WeSpeakerVoiceprints.windows(sampleCount: rate * 5 / 2) == [
            0..<length, half..<(half + length), (2 * half)..<(2 * half + length),
        ])
        // 2.2 s: the hop leaves the end uncovered, so a last window ends with the audio.
        let count = rate * 22 / 10
        #expect(WeSpeakerVoiceprints.windows(sampleCount: count) == [
            0..<length, half..<(half + length), (count - length)..<count,
        ])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func sameVoiceIsCloserThanDifferentVoices() async throws {
        let store = WeSpeakerVoiceprints()
        if !store.isInstalled() { try await store.install { _ in } }
        try await store.prepare()

        let samantha = try sayVoice("Samantha")
        let daniel = try sayVoice("Daniel")
        let first = try await store.voiceprints(
            of: sayClip("Standby lighting cue forty two and sound cue seventeen", voice: samantha), startingAt: 0)
        let second = try await store.voiceprints(
            of: sayClip("Lighting cue forty two go, and fly cue nine go", voice: samantha), startingAt: 10)
        let other = try await store.voiceprints(
            of: sayClip("Sound standing by for cue seventeen, thank you", voice: daniel), startingAt: 20)
        #expect(!first.isEmpty && !second.isEmpty && !other.isEmpty)
        #expect(first.allSatisfy { abs(norm($0.vector) - 1) < 1e-3 && $0.vector.count == 256 })
        #expect(zip(first, first.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(first.first?.start == 0)
        #expect(second.first?.start == 10)

        let same = meanDistance(first, second)
        let different = (meanDistance(first, other) + meanDistance(second, other)) / 2
        print("Voiceprints: same voice \(same), different voices \(different)")
        #expect(same + 0.1 <= different)

        // Cost: a 10 s line, embedded several times after the first (warm) call.
        let line = try sayClip(
            "Standby lighting cue forty two, sound cue seventeen, fly cue nine and video cue three. "
                + "Lighting, sound, flys and video, go.",
            voice: samantha)
        let clock = ContinuousClock()
        var windows = 0
        let runs = 5
        let elapsed = try await clock.measure {
            for _ in 0..<runs { windows += try await store.voiceprints(of: line, startingAt: 0).count }
        }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print(String(
            format: "Voiceprints: %.1f s line, %d windows per call, %.1f ms per call, %.2f ms per window",
            Double(line.count) / 16_000, windows / runs, ms / Double(runs), ms / Double(windows)))
    }

    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    private func meanDistance(_ a: [Voiceprint], _ b: [Voiceprint]) -> Double {
        var total = 0.0
        for x in a {
            for y in b { total += Double(1 - zip(x.vector, y.vector).reduce(0) { $0 + $1.0 * $1.1 }) }
        }
        return total / Double(a.count * b.count)
    }
}
