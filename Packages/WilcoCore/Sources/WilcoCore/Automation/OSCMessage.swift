import Foundation

/// An OSC 1.0 message.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// The message with `{text}`-style placeholders filled in its address and
    /// string arguments. Values are sanitised for the address, so what is
    /// heard on comms can never become an OSC wildcard pattern, and NUL
    /// bytes, which would end an OSC string early, are dropped from arguments.
    public func expanded(with context: TemplateContext) -> OSCMessage {
        var expandedAddress = context.expand(address, escaping: .oscAddress)
        if !expandedAddress.hasPrefix("/") { expandedAddress = "/" + expandedAddress }
        return OSCMessage(
            address: expandedAddress,
            arguments: arguments.map { argument in
                guard case .string(let template) = argument else { return argument }
                return .string(context.expand(template).replacingOccurrences(of: "\u{0}", with: ""))
            }
        )
    }

    /// The packet: padded address, type tags (`i f s T F`), then big-endian
    /// arguments, every part padded to four bytes.
    public func encoded() -> Data {
        var data = Self.padded(address)
        var tags = ","
        var payload = Data()
        for argument in arguments {
            switch argument {
            case .int(let value):
                tags += "i"
                withUnsafeBytes(of: value.bigEndian) { payload.append(contentsOf: $0) }
            case .float(let value):
                tags += "f"
                withUnsafeBytes(of: value.bitPattern.bigEndian) { payload.append(contentsOf: $0) }
            case .string(let value):
                tags += "s"
                payload.append(Self.padded(value))
            case .bool(let value):
                tags += value ? "T" : "F"
            }
        }
        data.append(Self.padded(tags))
        data.append(payload)
        return data
    }

    /// UTF-8, NUL-terminated, padded with NULs to a multiple of four.
    private static func padded(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
}

/// How OSC packets are delimited on each transport.
public enum OSCFraming {
    public static func frame(_ packet: Data, for transport: OSCTransport) -> Data {
        switch transport {
        case .udp:
            return packet
        case .tcpLengthPrefixed:
            var data = Data()
            withUnsafeBytes(of: UInt32(packet.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(packet)
            return data
        case .tcpSLIP:
            // Double-END SLIP (OSC 1.1): END, escaped packet, END.
            var data = Data([0xC0])
            for byte in packet {
                switch byte {
                case 0xC0: data.append(contentsOf: [0xDB, 0xDC])
                case 0xDB: data.append(contentsOf: [0xDB, 0xDD])
                default: data.append(byte)
                }
            }
            data.append(0xC0)
            return data
        }
    }
}
