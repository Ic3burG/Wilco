import Foundation

extension MIDIMessageSpec {
    /// The bytes to send. Channels are 1–16 as on a console; data bytes are
    /// clamped to 7 bits.
    public var bytes: [UInt8] {
        switch self {
        case .noteOn(let channel, let note, let velocity):
            [0x90 | Self.channelNibble(channel), note & 0x7F, min(velocity, 0x7F)]
        case .noteOff(let channel, let note):
            [0x80 | Self.channelNibble(channel), note & 0x7F, 0]
        case .controlChange(let channel, let controller, let value):
            [0xB0 | Self.channelNibble(channel), controller & 0x7F, min(value, 0x7F)]
        case .programChange(let channel, let program):
            [0xC0 | Self.channelNibble(channel), program & 0x7F]
        case .mscGo(let deviceID, let cueNumber, let cueList):
            Self.mscGo(deviceID: deviceID, cue: cueNumber, list: cueList)
        }
    }

    /// A short description for the Activity log.
    public var summary: String {
        switch self {
        case .noteOn(let channel, let note, let velocity): "Note On ch\(channel) \(note) vel \(velocity)"
        case .noteOff(let channel, let note): "Note Off ch\(channel) \(note)"
        case .controlChange(let channel, let controller, let value): "CC ch\(channel) #\(controller) = \(value)"
        case .programChange(let channel, let program): "Program Change ch\(channel) \(program)"
        case .mscGo(let deviceID, let cue, let list): "MSC GO device \(deviceID) cue \(cue)" + (list.isEmpty ? "" : " list \(list)")
        }
    }

    private static func channelNibble(_ channel: UInt8) -> UInt8 {
        min(max(channel, 1), 16) - 1
    }

    /// MIDI Show Control GO, command format Lighting (General), as 0.2.0 sent it:
    /// `F0 7F <device> 02 01 01 <cue> [00 <list>] F7`. Cue numbers keep only
    /// the digits and points MSC allows.
    private static func mscGo(deviceID: UInt8, cue: String, list: String) -> [UInt8] {
        let allowed = { (text: String) in text.utf8.filter { (0x30...0x39).contains($0) || $0 == 0x2E } }
        var bytes: [UInt8] = [0xF0, 0x7F, deviceID & 0x7F, 0x02, 0x01, 0x01]
        bytes += allowed(cue)
        let listBytes = allowed(list)
        if !listBytes.isEmpty {
            bytes += [0x00] + listBytes
        }
        bytes.append(0xF7)
        return bytes
    }
}
