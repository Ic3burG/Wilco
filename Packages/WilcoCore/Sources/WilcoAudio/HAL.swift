import CoreAudio
import Foundation
import WilcoCore

/// Thin, typed access to the CoreAudio hardware abstraction layer.
enum HAL {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        let operation: String

        var description: String { "\(operation) failed (\(status.fourCharacterCode))" }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as _: T.Type = T.self) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        guard status == noErr else { throw Failure(status: status, operation: "Reading property \(address.mSelector.fourCharacterCode)") }
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        // Nil both when the read fails and when the property holds no string.
        guard let value = try? Self.value(object, address, as: Unmanaged<CFString>?.self) else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: Devices

    static func allDevices() -> [AudioObjectID] {
        objects(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }

    static func defaultInputDevice() -> AudioObjectID? {
        let id = try? value(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), as: AudioObjectID.self)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        allDevices().first { self.uid(of: $0) == uid }
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    /// Channel count of each input stream, in order.
    static func inputBufferChannelCounts(of device: AudioObjectID) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Double {
        (try? value(device, address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
    }

    /// The IOProc reads samples as 32-bit floats. CoreAudio presents input
    /// in that format for virtually every device; anything else is refused.
    static func inputIsFloat32(_ device: AudioObjectID) -> Bool {
        let streams = objects(device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput))
        return streams.allSatisfy { stream in
            guard let format = try? value(stream, address(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self) else { return false }
            return format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
        }
    }

    static func info(for device: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = uid(of: device) else { return nil }
        let channels = inputBufferChannelCounts(of: device).reduce(0, +)
        guard channels > 0 else { return nil }
        let names = (1...channels).map { element in
            let name = string(device, address(kAudioObjectPropertyElementName, scope: kAudioObjectPropertyScopeInput, element: UInt32(element)))
            return (name?.isEmpty == false ? name! : "Input \(element)")
        }
        return AudioDeviceInfo(
            id: uid,
            name: string(device, address(kAudioObjectPropertyName)) ?? uid,
            manufacturer: string(device, address(kAudioObjectPropertyManufacturer)) ?? "",
            inputChannels: channels,
            channelNames: names,
            sampleRate: nominalSampleRate(of: device)
        )
    }
}

extension OSStatus {
    /// CoreAudio errors are usually four printable characters, e.g. `'!dev'`.
    var fourCharacterCode: String {
        UInt32(bitPattern: self).fourCharacterCode
    }
}

extension UInt32 {
    var fourCharacterCode: String {
        let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(self) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}
