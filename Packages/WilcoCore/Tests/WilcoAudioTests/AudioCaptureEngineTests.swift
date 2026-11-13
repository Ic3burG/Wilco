import Foundation
import Synchronization
import Testing
@testable import WilcoAudio
import WilcoCore

/// Exercises the engine against a device that is not connected, which needs
/// no microphone permission: the IOProc is never opened.
@Suite("Capture engine")
struct AudioCaptureEngineTests {
    private final class Recorder: Sendable {
        let states = Mutex<[CaptureHealth]>([])
        func append(_ health: CaptureHealth) { states.withLock { $0.append(health) } }
        var all: [CaptureHealth] { states.withLock { $0 } }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func missingDeviceKeepsRetryingThenStops() async {
        let recorder = Recorder()
        let engine = AudioCaptureEngine(onHealthChange: recorder.append)

        engine.start(deviceUID: "NOT-A-REAL-DEVICE", taps: [CaptureTap(id: UUID(), deviceChannel: 0)])
        await waitUntil { recorder.all.contains { $0.state == .recovering(attempt: 2) } }

        let states = recorder.all.map(\.state)
        #expect(states.first == .starting)
        #expect(states.contains(.recovering(attempt: 1)))
        #expect(states.contains(.recovering(attempt: 2)))
        #expect(recorder.all.last?.lastError == "The audio device is not connected")
        #expect(engine.takePeaks().isEmpty)

        engine.stop()
        await waitUntil { recorder.all.last?.state == .stopped }
        #expect(recorder.all.last?.state == .stopped)
    }
}
