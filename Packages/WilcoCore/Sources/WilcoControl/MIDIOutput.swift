import CoreMIDI
import Foundation
import WilcoCore

/// A MIDI destination as the user picks it.
public struct MIDIDestinationInfo: Identifiable, Hashable, Sendable {
    /// CoreMIDI unique ID: stable across launches for the same device.
    public var id: Int32
    public var name: String
}

/// Sends MIDI to CoreMIDI destinations through a client and port named "Wilco".
public final class MIDIOutput: @unchecked Sendable {
    public struct SendError: LocalizedError {
        public let errorDescription: String?
    }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let lock = NSLock()

    public init() {}

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    public static func destinations() -> [MIDIDestinationInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            var id: Int32 = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            return MIDIDestinationInfo(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI \(id)")
        }
    }

    public func send(_ message: MIDIMessageSpec, to destinationID: Int32) throws {
        let port = try outputPort()
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(destinationID, &object, &type) == noErr, type == .destination else {
            throw SendError(errorDescription: "MIDI destination is not connected")
        }

        // Room for a list header plus packets of up to four words each.
        let packets = UniversalMIDIPackets.words(for: message.bytes)
        let size = MemoryLayout<MIDIEventList>.size + packets.count * MemoryLayout<UInt32>.size * 8
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        for words in packets {
            packet = words.withUnsafeBufferPointer {
                MIDIEventListAdd(list, size, packet, 0, $0.count, $0.baseAddress!)
            }
        }
        let status = MIDISendEventList(port, MIDIEndpointRef(object), list)
        guard status == noErr else { throw SendError(errorDescription: "MIDI send failed (\(status))") }
    }

    private func outputPort() throws -> MIDIPortRef {
        lock.lock()
        defer { lock.unlock() }
        if port != 0 { return port }
        var status = MIDIClientCreateWithBlock("Wilco" as CFString, &client, nil)
        guard status == noErr else { throw SendError(errorDescription: "Could not create MIDI client (\(status))") }
        status = MIDIOutputPortCreate(client, "Wilco Out" as CFString, &port)
        guard status == noErr else { throw SendError(errorDescription: "Could not create MIDI output port (\(status))") }
        return port
    }
}
