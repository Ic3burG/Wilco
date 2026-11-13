import CoreAudio
import Foundation
import WilcoCore

/// Input devices on this Mac, and notice when that list changes.
public final class AudioDevices: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.ic3burg.wilco.audio.devices")
    private var observers: [HALPropertyObserver] = []

    /// Called on a background queue when devices are added or removed, or
    /// the system default input changes.
    public init(onChange: @escaping @Sendable () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        observers = [
            HALPropertyObserver(object: system, address: HAL.address(kAudioHardwarePropertyDevices), queue: queue, handler: onChange),
            HALPropertyObserver(object: system, address: HAL.address(kAudioHardwarePropertyDefaultInputDevice), queue: queue, handler: onChange),
        ]
    }

    /// Every device with at least one input channel, by name.
    public static func inputDevices() -> [AudioDeviceInfo] {
        HAL.allDevices()
            .compactMap(HAL.info(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func defaultInputUID() -> String? {
        HAL.defaultInputDevice().flatMap(HAL.uid(of:))
    }
}
