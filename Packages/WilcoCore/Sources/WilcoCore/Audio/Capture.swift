import Foundation

/// A channel to capture: which show channel, from which device input.
public struct CaptureTap: Hashable, Sendable {
    public var id: UUID
    /// Device to capture from; `nil` follows the system default input.
    public var deviceUID: String?
    /// Zero-based input across all of the device's input streams.
    public var deviceChannel: Int

    public init(id: UUID, deviceUID: String? = nil, deviceChannel: Int) {
        self.id = id
        self.deviceUID = deviceUID
        self.deviceChannel = deviceChannel
    }
}

/// Where a tap's samples sit in the IOProc's `AudioBufferList`.
public struct CaptureRoute: Equatable, Sendable {
    public var tapID: UUID
    public var bufferIndex: Int
    public var channelInBuffer: Int
    /// Index into the capture's peak slots and rings.
    public var slot: Int

    public init(tapID: UUID, bufferIndex: Int, channelInBuffer: Int, slot: Int) {
        self.tapID = tapID
        self.bufferIndex = bufferIndex
        self.channelInBuffer = channelInBuffer
        self.slot = slot
    }
}

public enum CaptureRouting {
    public struct Plan: Equatable, Sendable {
        public var routes: [CaptureRoute]
        /// Taps patched to an input the device does not have.
        public var unroutable: [UUID]
    }

    /// A device can present its inputs as several streams (buffers). Device
    /// channel numbers run across them in order.
    public static func plan(taps: [CaptureTap], bufferChannelCounts: [Int]) -> Plan {
        var plan = Plan(routes: [], unroutable: [])
        for tap in taps {
            // Routes index raw audio memory on the real-time thread, so only
            // inputs that provably exist are ever routed.
            guard tap.deviceChannel >= 0 else {
                plan.unroutable.append(tap.id)
                continue
            }
            var remaining = tap.deviceChannel
            var routed = false
            for (bufferIndex, channels) in bufferChannelCounts.enumerated() {
                if remaining < channels {
                    plan.routes.append(CaptureRoute(
                        tapID: tap.id, bufferIndex: bufferIndex,
                        channelInBuffer: remaining, slot: plan.routes.count
                    ))
                    routed = true
                    break
                }
                remaining -= channels
            }
            if !routed { plan.unroutable.append(tap.id) }
        }
        return plan
    }
}

/// When to give up on a silent device and how long to wait between rebuilds.
public struct RecoveryPolicy: Sendable {
    public var stallTimeout: Double = 2
    public var initialDelay: Double = 0.5
    public var maximumDelay: Double = 8

    public init() {}

    public func isStalled(secondsSinceLastCallback: Double) -> Bool {
        secondsSinceLastCallback > stallTimeout
    }

    /// Delay before rebuild attempt `attempt` (1-based): 0.5, 1, 2, 4, 8, 8…
    public func delay(forAttempt attempt: Int) -> Double {
        min(maximumDelay, initialDelay * pow(2, Double(max(0, attempt - 1))))
    }
}

public enum CaptureState: Equatable, Sendable {
    case stopped
    case starting
    case running
    /// Rebuilding after the device stalled, changed or disappeared.
    case recovering(attempt: Int)
    case failed
}

public struct CaptureHealth: Equatable, Sendable {
    public var state: CaptureState = .stopped
    public var deviceName = ""
    public var deviceUID = ""
    public var sampleRate: Double = 0
    public var channelCount = 0
    /// Times the device was rebuilt after dropping out, this session.
    public var recoveryCount = 0
    /// Increments on every successful (re)start.
    public var generation = 0
    /// Frames discarded because transcription fell behind.
    public var droppedFrames = 0
    public var secondsSinceLastCallback: Double = 0
    public var lastError: String?

    public init() {}
}

/// An audio input device as the user picks it.
public struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    /// CoreAudio device UID: stable across reboots and replugging.
    public var id: String
    public var name: String
    public var manufacturer: String
    public var inputChannels: Int
    public var channelNames: [String]
    public var sampleRate: Double

    public init(id: String, name: String, manufacturer: String, inputChannels: Int, channelNames: [String], sampleRate: Double) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannels = inputChannels
        self.channelNames = channelNames
        self.sampleRate = sampleRate
    }
}

extension ShowDocument {
    /// The device a channel captures from: its own, else the show's. `nil`
    /// means the system default input.
    public func deviceUID(for channelID: ChannelConfig.ID) -> String? {
        channel(id: channelID)?.deviceUID ?? deviceUID
    }

    /// Patched channels, muted or not: muted channels still meter.
    public var captureTaps: [CaptureTap] {
        channels.compactMap { channel in
            channel.deviceChannel.map {
                CaptureTap(id: channel.id, deviceUID: channel.deviceUID ?? deviceUID, deviceChannel: $0)
            }
        }
    }

    /// Whether `other` captures exactly the same inputs, in any order. Only a
    /// change here needs capture restarted: reordering or grouping channels
    /// mid-show must not drop audio.
    public func capturesSameInputs(as other: ShowDocument) -> Bool {
        Set(captureTaps) == Set(other.captureTaps)
    }
}
