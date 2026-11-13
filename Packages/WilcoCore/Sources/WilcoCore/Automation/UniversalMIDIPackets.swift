/// Converts MIDI 1.0 byte messages to Universal MIDI Packets, which CoreMIDI's
/// current send API takes. Group 0 throughout.
public enum UniversalMIDIPackets {
    /// One array of 32-bit words per packet.
    public static func words(for bytes: [UInt8]) -> [[UInt32]] {
        guard let status = bytes.first else { return [] }
        if status == 0xF0 {
            return sysEx(Array(bytes.dropFirst().prefix { $0 != 0xF7 }))
        }
        // MIDI 1.0 channel voice message (type 2): status, then up to two data bytes.
        let data1 = bytes.count > 1 ? UInt32(bytes[1]) : 0
        let data2 = bytes.count > 2 ? UInt32(bytes[2]) : 0
        return [[0x2000_0000 | UInt32(status) << 16 | data1 << 8 | data2]]
    }

    /// 7-bit system exclusive (type 3): up to six payload bytes per packet,
    /// marked complete, start, continue or end.
    private static func sysEx(_ payload: [UInt8]) -> [[UInt32]] {
        let chunks = payload.isEmpty ? [[]] : stride(from: 0, to: payload.count, by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            let status: UInt32 = switch (index == 0, index == chunks.count - 1) {
            case (true, true): 0x0   // complete in one packet
            case (true, false): 0x1  // start
            case (false, false): 0x2 // continue
            case (false, true): 0x3  // end
            }
            let padded = chunk.map(UInt32.init) + Array(repeating: 0, count: 6 - chunk.count)
            let first = 0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | padded[0] << 8 | padded[1]
            let second = padded[2] << 24 | padded[3] << 16 | padded[4] << 8 | padded[5]
            return [first, second]
        }
    }
}
