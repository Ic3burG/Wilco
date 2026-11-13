import CoreAudio
import Foundation
import Synchronization
import WilcoCore

/// Captures selected inputs of one CoreAudio device directly through an IOProc,
/// and rebuilds the capture when the device stalls, changes or disappears.
///
/// All state is confined to `queue`. The IOProc runs on CoreAudio's real-time
/// thread and touches only its ``RTContext``.
public final class AudioCaptureEngine: @unchecked Sendable {
    public typealias HealthHandler = @Sendable (CaptureHealth) -> Void

    private let queue = DispatchQueue(label: "io.github.ic3burg.wilco.audio.capture", qos: .userInteractive)
    private let policy = RecoveryPolicy()
    private let onHealthChange: HealthHandler

    // Desired state.
    private var isEnabled = false
    private var requestedUID: String?
    private var taps: [CaptureTap] = []

    // Live capture.
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var deviceObservers: [HALPropertyObserver] = []
    private var systemObservers: [HALPropertyObserver] = []
    private var watchdog: DispatchSourceTimer?
    private var recoveryAttempt = 0
    /// Bumped whenever a scheduled restart becomes stale.
    private var restartToken = 0
    private var health = CaptureHealth()

    /// The context the UI reads meters from. The IOProc holds its own reference.
    private let published = Mutex<RTContext?>(nil)
    /// Where each tap's samples go. Owned by the caller, so a transcriber's
    /// source survives a device dropout or a move to another device.
    private let rings = Mutex<[UUID: AudioRingBuffer]>([:])
    private let currentSampleRate = Mutex<Double>(0)

    public init(onHealthChange: @escaping HealthHandler) {
        self.onHealthChange = onHealthChange
    }

    // MARK: Control

    /// Starts capturing, or reconfigures a running capture. `deviceUID` nil
    /// follows the system default input. Each tap's samples are written to
    /// its ring in `rings`; taps without one are metered only.
    public func start(deviceUID: String?, taps: [CaptureTap], rings: [UUID: AudioRingBuffer] = [:]) {
        self.rings.withLock { $0 = rings }
        queue.async { [self] in
            let changed = !isEnabled || deviceUID != requestedUID || taps != self.taps
            isEnabled = true
            requestedUID = deviceUID
            self.taps = taps
            guard changed else { return }
            health.recoveryCount = isRunningLocked ? health.recoveryCount : 0
            installSystemObservers()
            restart(reason: nil, after: 0)
        }
    }

    public func stop() {
        queue.async { [self] in
            isEnabled = false
            restartToken += 1
            tearDown()
            systemObservers = []
            watchdog?.cancel()
            watchdog = nil
            recoveryAttempt = 0
            health.state = .stopped
            health.secondsSinceLastCallback = 0
            publish()
        }
    }

    /// The running device's sample rate, or the last one seen.
    public var sampleRate: Double {
        currentSampleRate.withLock { $0 }
    }

    /// Peak level per tap since the last call, as linear amplitude.
    public func takePeaks() -> [UUID: Float] {
        published.withLock { context in
            guard let context else { return [:] }
            var peaks: [UUID: Float] = [:]
            for route in context.routes {
                peaks[route.tapID] = context.peaks.take(route.slot)
            }
            return peaks
        }
    }

    // MARK: Lifecycle (on queue)

    private var isRunningLocked: Bool { procID != nil }

    private func restart(reason: String?, after delay: Double) {
        tearDown()
        restartToken += 1
        let token = restartToken
        if let reason {
            recoveryAttempt += 1
            health.recoveryCount += 1
            health.state = .recovering(attempt: recoveryAttempt)
            health.lastError = reason
        } else {
            health.state = .starting
        }
        publish()
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard isEnabled, token == restartToken else { return }
            do {
                try bringUp()
                recoveryAttempt = 0
            } catch {
                let attempt = recoveryAttempt + 1
                recoveryAttempt = attempt
                health.state = .recovering(attempt: attempt)
                health.lastError = String(describing: error)
                publish()
                restartLater(after: policy.delay(forAttempt: attempt))
            }
        }
        startWatchdog()
    }

    /// Retries without counting a new dropout.
    private func restartLater(after delay: Double) {
        restartToken += 1
        let token = restartToken
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard isEnabled, token == restartToken, !isRunningLocked else { return }
            do {
                try bringUp()
                recoveryAttempt = 0
            } catch {
                recoveryAttempt += 1
                health.lastError = String(describing: error)
                health.state = .recovering(attempt: recoveryAttempt)
                publish()
                restartLater(after: policy.delay(forAttempt: recoveryAttempt))
            }
        }
    }

    private func bringUp() throws {
        guard let device = requestedUID.map(HAL.device(withUID:)) ?? HAL.defaultInputDevice() else {
            throw CaptureError("The audio device is not connected")
        }
        guard HAL.inputIsFloat32(device) else {
            throw CaptureError("The audio device does not provide 32-bit float input")
        }
        let counts = HAL.inputBufferChannelCounts(of: device)
        let plan = CaptureRouting.plan(taps: taps, bufferChannelCounts: counts)
        let routeRings = rings.withLock { rings in plan.routes.map { rings[$0.tapID] } }
        let context = RTContext(routes: plan.routes, rings: routeRings)
        currentSampleRate.withLock { $0 = HAL.nominalSampleRate(of: device) }

        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device, nil) { _, input, _, _, _ in
            context.process(input)
        }
        guard status == noErr, let newProcID else {
            throw HAL.Failure(status: status, operation: "Opening the audio device")
        }
        status = AudioDeviceStart(device, newProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, newProcID)
            throw HAL.Failure(status: status, operation: "Starting the audio device")
        }

        deviceID = device
        procID = newProcID
        published.withLock { $0 = context }
        observe(device)

        let info = HAL.info(for: device)
        health.state = .running
        health.deviceName = info?.name ?? ""
        health.deviceUID = info?.id ?? ""
        health.sampleRate = HAL.nominalSampleRate(of: device)
        health.channelCount = counts.reduce(0, +)
        health.generation += 1
        health.secondsSinceLastCallback = 0
        health.lastError = plan.unroutable.isEmpty ? nil
            : "\(plan.unroutable.count) channel(s) are patched to inputs this device does not have"
        publish()
    }

    private func tearDown() {
        deviceObservers = []
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        published.withLock { $0 = nil }
    }

    // MARK: Watching for trouble

    private func observe(_ device: AudioObjectID) {
        let rebuild = { [weak self] (reason: String) -> () -> Void in
            { self?.restart(reason: reason, after: 0.2) }
        }
        deviceObservers = [
            HALPropertyObserver(object: device, address: HAL.address(kAudioDevicePropertyDeviceIsAlive), queue: queue,
                                handler: rebuild("The audio device disconnected")),
            HALPropertyObserver(object: device, address: HAL.address(kAudioDevicePropertyNominalSampleRate), queue: queue,
                                handler: rebuild("Sample rate changed")),
            HALPropertyObserver(object: device, address: HAL.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
                                queue: queue, handler: rebuild("Stream configuration changed")),
        ]
    }

    /// A device coming back, or the default input changing, restarts at once.
    private func installSystemObservers() {
        guard systemObservers.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemObservers = [
            HALPropertyObserver(object: system, address: HAL.address(kAudioHardwarePropertyDevices), queue: queue) { [weak self] in
                guard let self, isEnabled, !isRunningLocked else { return }
                restartLater(after: 0.2)
            },
            HALPropertyObserver(object: system, address: HAL.address(kAudioHardwarePropertyDefaultInputDevice), queue: queue) { [weak self] in
                guard let self, isEnabled, requestedUID == nil else { return }
                restart(reason: nil, after: 0.2)
            },
        ]
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        watchdog = timer
    }

    private func checkForStall() {
        guard isEnabled, let context = published.withLock({ $0 }) else { return }
        let age = context.secondsSinceLastCallback
        health.secondsSinceLastCallback = age
        let dropped = rings.withLock { $0.values.reduce(0) { $0 + $1.droppedFrames } }
        if dropped != health.droppedFrames {
            health.droppedFrames = dropped
            publish()
        }
        if policy.isStalled(secondsSinceLastCallback: age) {
            restart(reason: "The audio device stopped delivering audio", after: policy.delay(forAttempt: recoveryAttempt + 1))
        }
    }

    private func publish() {
        onHealthChange(health)
    }
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Everything the IOProc touches. Built once per capture and never mutated
/// afterwards, apart from the atomics.
final class RTContext: @unchecked Sendable {
    let routes: [CaptureRoute]
    let peaks: PeakSlots
    /// Indexed by route slot; nil for taps that are only metered.
    private let rings: ContiguousArray<AudioRingBuffer?>
    private let routeBuffer: UnsafeMutableBufferPointer<CaptureRoute>
    private let lastCallbackNanos: Atomic<UInt64>
    private let createdNanos: UInt64

    init(routes: [CaptureRoute], rings: [AudioRingBuffer?]) {
        precondition(rings.count == routes.count)
        self.routes = routes
        self.rings = ContiguousArray(rings)
        peaks = PeakSlots(count: routes.count)
        routeBuffer = .allocate(capacity: routes.count)
        _ = routeBuffer.initialize(from: routes)
        createdNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lastCallbackNanos = Atomic(createdNanos)
    }

    deinit {
        routeBuffer.deallocate()
    }

    var secondsSinceLastCallback: Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - lastCallbackNanos.load(ordering: .relaxed)) / 1e9
    }

    /// Real-time thread. No allocation, locks or Swift arrays.
    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for route in routeBuffer {
            guard route.bufferIndex < buffers.count else { continue }
            let buffer = buffers[route.bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, route.channelInBuffer >= 0, route.channelInBuffer < channels,
                  let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let first = data.assumingMemoryBound(to: Float.self) + route.channelInBuffer
            peaks.record(LevelMath.peak(first, count: frames, stride: channels), at: route.slot)
            rings[route.slot]?.write(first, count: frames, stride: channels)
        }
        lastCallbackNanos.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
    }
}
