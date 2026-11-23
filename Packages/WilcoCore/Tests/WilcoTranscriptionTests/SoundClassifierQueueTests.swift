import Foundation
import Synchronization
import Testing
@testable import WilcoCore
@testable import WilcoTranscription

@Suite("Sound classifier queue")
struct SoundClassifierQueueTests {
    static let clip = MeterClip(samples: [Float](repeating: 0.1, count: 160), sampleRate: 16_000)
    static let shares = SoundShares(speech: 0.9, music: 0.1, singing: 0)

    /// Lets a test hold classifications until it releases them.
    final class Gate: Sendable {
        private let open = Mutex(false)
        func release() { open.withLock { $0 = true } }
        func wait() async {
            while !open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    @Test func classifiesOneAtATime() async {
        let state = Mutex((now: 0, peak: 0))
        let queue = SoundClassifierQueue(maxWaiting: 64) { _ in
            state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            try? await Task.sleep(for: .milliseconds(10))
            state.withLock { $0.now -= 1 }
            return Self.shares
        }
        let results = await withTaskGroup(of: SoundShares?.self) { group in
            for _ in 0..<10 { group.addTask { await queue.classify(Self.clip) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 != nil })
        #expect(state.withLock { $0.peak } == 1)
    }

    @Test func dropsWhenTooManyWait() async {
        let gate = Gate()
        let queue = SoundClassifierQueue(maxWaiting: 2) { _ in
            await gate.wait()
            return Self.shares
        }
        let results = await withTaskGroup(of: SoundShares?.self) { group in
            for _ in 0..<5 { group.addTask { await queue.classify(Self.clip) } }
            // The two that find the line full come back at once.
            var early: [SoundShares?] = []
            while early.count < 2, let next = await group.next() { early.append(next) }
            #expect(early.allSatisfy { $0 == nil })
            gate.release()
            return early + (await group.reduce(into: []) { $0.append($1) })
        }
        #expect(results.filter { $0 == nil }.count == 2)
        #expect(results.filter { $0 != nil }.count == 3)
        #expect(await queue.droppedClips == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func builtInHearsSpeech() async throws {
        let samples = try sayClip("Standby lighting cue forty two, go lighting cue forty two")
        let clip = MeterClip(samples: Array(samples.prefix(48_000)), sampleRate: 16_000)
        let shares = try #require(await SoundClassifierQueue.builtIn(clip))
        #expect(shares.speech > shares.music, "speech \(shares.speech), music \(shares.music)")
    }
}
