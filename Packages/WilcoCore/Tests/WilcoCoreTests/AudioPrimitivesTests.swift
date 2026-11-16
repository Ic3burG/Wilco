import Foundation
import Testing
@testable import WilcoCore

@Suite("Audio history")
struct AudioHistoryTests {
    /// Each sample holds the time it was heard, at 100 samples a second.
    private func ramp(from start: Double, seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(start + Double($0) / rate) }
    }

    @Test func keepsTheLastThirtySeconds() {
        var history = AudioHistory(sampleRate: 100, seconds: 30)
        // 40 s in four chunks, ending 40 s into the session.
        for chunk in 0..<4 {
            history.append(ramp(from: Double(chunk) * 10, seconds: 10, rate: 100), endingAt: Double(chunk + 1) * 10)
        }
        let all = history.samples(from: 0, to: 40)
        #expect(all.count == 3_000)
        #expect(abs((all.first ?? 0) - 10) < 0.02)
        #expect(abs((all.last ?? 0) - 39.99) < 0.02)

        let span = history.samples(from: 32, to: 33.5)
        #expect(span.count == 150)
        #expect(abs((span.first ?? 0) - 32) < 0.02)
    }

    @Test func spanBeforeHistoryReturnsWhatRemains() {
        var history = AudioHistory(sampleRate: 100, seconds: 30)
        history.append(ramp(from: 0, seconds: 40, rate: 100), endingAt: 40)
        // 5 to 15 s: only 10 to 15 s is still held.
        let span = history.samples(from: 5, to: 15)
        #expect(span.count == 500)
        #expect(abs((span.first ?? 0) - 10) < 0.02)
        // Wholly before the history, or after it: nothing.
        #expect(history.samples(from: 0, to: 9).isEmpty)
        #expect(history.samples(from: 41, to: 45).isEmpty)
        #expect(AudioHistory().samples(from: 0, to: 1).isEmpty)
    }

    @Test func aChunkThatCouldNotBeConvertedStillMovesTheTimelineOn() {
        // A second of audio, a second the resampler failed on, then another
        // second: the third second is still found where it was heard.
        var history = AudioHistory(sampleRate: 100, seconds: 30)
        history.append(ramp(from: 0, seconds: 1, rate: 100), lasting: 1)
        history.append(nil, lasting: 1)
        history.append(ramp(from: 2, seconds: 1, rate: 100), lasting: 1)

        let third = history.samples(from: 2, to: 3)
        #expect(third.count == 100)
        #expect(abs((third.first ?? 0) - 2) < 0.02)
        // The lost second reads back as silence.
        #expect(history.samples(from: 1, to: 2) == [Float](repeating: 0, count: 100))
        #expect(abs((history.samples(from: 0, to: 1).last ?? 0) - 0.99) < 0.02)
    }
}

@Suite("Audio ring buffer")
struct AudioRingBufferTests {
    @Test func readsBackWhatWasWrittenAcrossTheWrapPoint() {
        let ring = AudioRingBuffer(capacity: 4)
        _ = ring.write([1, 2, 3])
        #expect(ring.read(maxCount: 2) == [1, 2])
        _ = ring.write([4, 5, 6])

        #expect(ring.availableToRead == 4)
        #expect(ring.read(maxCount: 10) == [3, 4, 5, 6])
        #expect(ring.availableToRead == 0)
    }

    @Test func dropsAndCountsFramesThatDoNotFit() {
        let ring = AudioRingBuffer(capacity: 4)
        _ = ring.read(maxCount: 1)  // a reader is attached
        let written = ring.write([1, 2, 3, 4, 5, 6])

        #expect(written == 4)
        #expect(ring.droppedFrames == 2)
        #expect(ring.read(maxCount: 10) == [1, 2, 3, 4])
    }

    @Test func overflowWithNoReaderIsNotCountedAsDropped() {
        let ring = AudioRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5, 6])
        #expect(ring.droppedFrames == 0)
    }

    @Test func stridedWriteDeinterleavesOneChannel() {
        let ring = AudioRingBuffer(capacity: 8)
        // Three interleaved channels; take the middle one.
        let interleaved: [Float] = [10, 20, 30, 11, 21, 31, 12, 22, 32]
        interleaved.withUnsafeBufferPointer { buffer in
            _ = ring.write(buffer.baseAddress! + 1, count: 3, stride: 3)
        }
        #expect(ring.read(maxCount: 8) == [20, 21, 22])
    }
}

@Suite("Peak slots")
struct PeakSlotsTests {
    @Test func keepsTheHighestPeakUntilTaken() {
        let slots = PeakSlots(count: 2)
        slots.record(0.25, at: 0)
        slots.record(0.75, at: 0)
        slots.record(0.5, at: 0)
        slots.record(0.1, at: 1)

        #expect(slots.take(0) == 0.75)
        #expect(slots.take(0) == 0)
        #expect(slots.take(1) == 0.1)
    }
}

@Suite("Level maths")
struct LevelMathTests {
    @Test func peakIsLargestMagnitudeOnTheStride() {
        let samples: [Float] = [0.1, -0.9, -0.5, 0.2, 0.3, 0.8]
        let peak = samples.withUnsafeBufferPointer { LevelMath.peak($0.baseAddress!, count: 3, stride: 2) }
        #expect(peak == 0.5)
    }

    @Test func meterPositionIsLinearInDecibels() {
        #expect(LevelMath.meterPosition(1) == 1)
        #expect(LevelMath.meterPosition(0) == 0)
        #expect(abs(LevelMath.meterPosition(0.001) - 0) < 0.0001)   // -60 dBFS
        #expect(abs(LevelMath.meterPosition(0.0316228) - 0.5) < 0.001) // -30 dBFS
        #expect(LevelMath.meterPosition(2) == 1)
    }
}

@Suite("Capture routing")
struct CaptureRoutingTests {
    @Test func mapsDeviceChannelsAcrossBuffers() {
        let a = UUID(), b = UUID(), c = UUID()
        // Device presents two streams: 2 channels then 4 channels.
        let plan = CaptureRouting.plan(
            taps: [CaptureTap(id: a, deviceChannel: 1), CaptureTap(id: b, deviceChannel: 4), CaptureTap(id: c, deviceChannel: 9)],
            bufferChannelCounts: [2, 4]
        )

        #expect(plan.routes == [
            CaptureRoute(tapID: a, bufferIndex: 0, channelInBuffer: 1, slot: 0),
            CaptureRoute(tapID: b, bufferIndex: 1, channelInBuffer: 2, slot: 1),
        ])
        #expect(plan.unroutable == [c])
    }

    @Test func negativeInputsAreNeverRouted() {
        let bad = UUID()
        let plan = CaptureRouting.plan(taps: [CaptureTap(id: bad, deviceChannel: -1)], bufferChannelCounts: [0, 2])
        #expect(plan.routes.isEmpty)
        #expect(plan.unroutable == [bad])
    }

    @Test func showFileWithNegativeInputDecodesAsUnpatched() throws {
        let json = #"{"id":"39810948-EF13-449A-BD50-3B5A55BB058B","name":"Bad","deviceChannel":-3}"#
        let channel = try WilcoJSON.decoder().decode(ChannelConfig.self, from: Data(json.utf8))
        #expect(channel.deviceChannel == nil)
    }
}

@Suite("Recovery policy")
struct RecoveryPolicyTests {
    @Test func backsOffAndCaps() {
        let policy = RecoveryPolicy()
        #expect(policy.delay(forAttempt: 1) == 0.5)
        #expect(policy.delay(forAttempt: 2) == 1)
        #expect(policy.delay(forAttempt: 4) == 4)
        #expect(policy.delay(forAttempt: 10) == 8)
    }

    @Test func stallsAfterTheTimeout() {
        let policy = RecoveryPolicy()
        #expect(policy.isStalled(secondsSinceLastCallback: 0.5) == false)
        #expect(policy.isStalled(secondsSinceLastCallback: 2.5) == true)
    }
}

@Suite("Capture taps")
struct CaptureTapTests {
    @Test func onlyPatchedChannelsAreCaptured() {
        var show = ShowDocument()
        let patched = show.addChannel()
        show.channels.append(ChannelConfig(name: "Unpatched"))

        #expect(show.captureTaps == [CaptureTap(id: patched.id, deviceChannel: 0)])
    }

    @Test func channelsUseTheShowDeviceUnlessTheyNameTheirOwn() {
        var show = ShowDocument(deviceUID: "DANTE")
        let onShowDevice = show.addChannel()
        let onLaptop = show.addChannel()
        show.updateChannel(id: onLaptop.id) { $0.deviceUID = "BUILTIN" }

        #expect(show.captureTaps.map(\.deviceUID) == ["DANTE", "BUILTIN"])
        #expect(show.deviceUID(for: onShowDevice.id) == "DANTE")

        show.deviceUID = nil  // system default input
        #expect(show.captureTaps.map(\.deviceUID) == [nil, "BUILTIN"])
    }

    @Test func channelDeviceIsOptionalInShowFiles() throws {
        let legacy = #"{"id":"39810948-EF13-449A-BD50-3B5A55BB058B","name":"Old","deviceChannel":2}"#
        let channel = try WilcoJSON.decoder().decode(ChannelConfig.self, from: Data(legacy.utf8))
        #expect(channel.deviceUID == nil)

        let encoded = String(decoding: try WilcoJSON.encoder().encode(channel), as: UTF8.self)
        #expect(!encoded.contains("deviceUID"), "older files should round-trip without new keys")
    }
}
