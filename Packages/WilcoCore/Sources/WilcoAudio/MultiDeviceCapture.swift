import Foundation
import Synchronization
import WilcoCore

/// Captures from several input devices at once: one ``AudioCaptureEngine``
/// per device in use, each with its own clock and its own recovery, so a
/// dropout on one device only affects its own channels.
///
/// Owns each channel's ring, so a channel keeps the same ring (and its
/// transcriber keeps its source) when it moves between devices.
public final class MultiDeviceCapture: @unchecked Sendable {
    /// Health per device, keyed by device UID (``systemDefaultKey`` for the
    /// system default input). Only devices in use appear.
    public typealias HealthHandler = @Sendable ([String: CaptureHealth]) -> Void

    public static let systemDefaultKey = ""
    /// About 10 s at 48 kHz.
    private static let ringCapacity = 480_000

    private struct State {
        var engines: [String: AudioCaptureEngine] = [:]
        var health: [String: CaptureHealth] = [:]
        var rings: [UUID: AudioRingBuffer] = [:]
        var engineForTap: [UUID: String] = [:]
    }

    private let state = Mutex(State())
    private let onHealthChange: HealthHandler

    public init(onHealthChange: @escaping HealthHandler) {
        self.onHealthChange = onHealthChange
    }

    /// Starts capturing `taps`, or reconfigures a running capture: devices
    /// no longer used stop, new ones start, unchanged ones carry on.
    public func start(taps: [CaptureTap]) {
        let byDevice = Dictionary(grouping: taps) { $0.deviceUID ?? Self.systemDefaultKey }
        var toStart: [(AudioCaptureEngine, String, [CaptureTap], [UUID: AudioRingBuffer])] = []
        var toStop: [AudioCaptureEngine] = []

        let snapshot = state.withLock { state in
            let ids = Set(taps.map(\.id))
            state.rings = state.rings.filter { ids.contains($0.key) }
            for id in ids where state.rings[id] == nil {
                state.rings[id] = AudioRingBuffer(capacity: Self.ringCapacity)
            }
            state.engineForTap = Dictionary(uniqueKeysWithValues: taps.map { ($0.id, $0.deviceUID ?? Self.systemDefaultKey) })

            for (key, engine) in state.engines where byDevice[key] == nil {
                toStop.append(engine)
                state.engines[key] = nil
                state.health[key] = nil
            }
            for (key, deviceTaps) in byDevice {
                let engine = state.engines[key] ?? makeEngine(key: key)
                state.engines[key] = engine
                let rings = state.rings.filter { ring in deviceTaps.contains { $0.id == ring.key } }
                toStart.append((engine, key, deviceTaps, rings))
            }
            return state.health
        }

        for engine in toStop { engine.stop() }
        for (engine, key, deviceTaps, rings) in toStart {
            engine.start(deviceUID: key == Self.systemDefaultKey ? nil : key, taps: deviceTaps, rings: rings)
        }
        onHealthChange(snapshot)
    }

    public func stop() {
        let engines = state.withLock { state in
            defer {
                state.engines = [:]
                state.health = [:]
                state.engineForTap = [:]
            }
            return Array(state.engines.values)
        }
        for engine in engines { engine.stop() }
        onHealthChange([:])
    }

    /// Mono samples captured for a channel, at ``sampleRate(for:)``.
    public func ring(for tapID: UUID) -> AudioRingBuffer? {
        state.withLock { $0.rings[tapID] }
    }

    /// The capture rate of the device a channel is on, or 0 if unknown.
    public func sampleRate(for tapID: UUID) -> Double {
        let engine = state.withLock { state in state.engineForTap[tapID].flatMap { state.engines[$0] } }
        return engine?.sampleRate ?? 0
    }

    /// Peak level per channel since the last call, across every device.
    public func takePeaks() -> [UUID: Float] {
        let engines = state.withLock { Array($0.engines.values) }
        return engines.reduce(into: [:]) { peaks, engine in
            peaks.merge(engine.takePeaks()) { max($0, $1) }
        }
    }

    private func makeEngine(key: String) -> AudioCaptureEngine {
        AudioCaptureEngine { [weak self] health in
            guard let self else { return }
            let snapshot: [String: CaptureHealth]? = state.withLock { state in
                // A stopped engine reports once more after it was removed.
                guard state.engines[key] != nil else { return nil }
                state.health[key] = health
                return state.health
            }
            if let snapshot { onHealthChange(snapshot) }
        }
    }
}
