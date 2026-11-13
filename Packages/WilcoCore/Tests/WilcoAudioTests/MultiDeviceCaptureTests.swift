import Foundation
import Synchronization
import Testing
@testable import WilcoAudio
import WilcoCore

/// Uses devices that are not connected, so no microphone permission is needed.
@Suite("Multi-device capture")
struct MultiDeviceCaptureTests {
    private final class Latest: Sendable {
        let health = Mutex<[String: CaptureHealth]>([:])
        func update(_ value: [String: CaptureHealth]) { health.withLock { $0 = value } }
        var value: [String: CaptureHealth] { health.withLock { $0 } }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func runsOneCapturePerDevice() async {
        let latest = Latest()
        let capture = MultiDeviceCapture(onHealthChange: latest.update)
        let a = UUID(), b = UUID(), c = UUID()

        capture.start(taps: [
            CaptureTap(id: a, deviceUID: "FAKE-DANTE", deviceChannel: 0),
            CaptureTap(id: b, deviceUID: "FAKE-DANTE", deviceChannel: 1),
            CaptureTap(id: c, deviceUID: "FAKE-LAPTOP", deviceChannel: 0),
        ])
        await waitUntil { latest.value.count == 2 && latest.value.values.allSatisfy { $0.state != .starting } }

        #expect(Set(latest.value.keys) == ["FAKE-DANTE", "FAKE-LAPTOP"])
        #expect(latest.value.values.allSatisfy { $0.lastError == "The audio device is not connected" })

        capture.stop()
        await waitUntil { latest.value.isEmpty }
        #expect(latest.value.isEmpty)
    }

    @Test func aChannelKeepsItsRingWhenItMovesDevice() async {
        let capture = MultiDeviceCapture(onHealthChange: { _ in })
        let channel = UUID()

        capture.start(taps: [CaptureTap(id: channel, deviceUID: "FAKE-DANTE", deviceChannel: 0)])
        let before = capture.ring(for: channel)
        capture.start(taps: [CaptureTap(id: channel, deviceUID: "FAKE-LAPTOP", deviceChannel: 3)])

        #expect(before != nil)
        #expect(capture.ring(for: channel) === before)

        capture.start(taps: [])
        #expect(capture.ring(for: channel) == nil)
        capture.stop()
    }

    @Test func devicesNoLongerUsedAreDropped() async {
        let latest = Latest()
        let capture = MultiDeviceCapture(onHealthChange: latest.update)
        let a = UUID(), b = UUID()

        capture.start(taps: [
            CaptureTap(id: a, deviceUID: "FAKE-DANTE", deviceChannel: 0),
            CaptureTap(id: b, deviceUID: "FAKE-LAPTOP", deviceChannel: 0),
        ])
        await waitUntil { latest.value.count == 2 }
        capture.start(taps: [CaptureTap(id: a, deviceUID: "FAKE-DANTE", deviceChannel: 0)])
        await waitUntil { latest.value.count == 1 }

        #expect(Set(latest.value.keys) == ["FAKE-DANTE"])
        capture.stop()
    }
}
