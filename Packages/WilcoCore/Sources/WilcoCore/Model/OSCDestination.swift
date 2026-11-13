import Foundation

/// A console or show-control machine that receives OSC.
public struct OSCDestination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var transport: OSCTransport
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        transport: OSCTransport = .udp,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.transport = transport
        self.isEnabled = isEnabled
    }
}

public enum OSCTransport: String, Codable, CaseIterable, Sendable {
    case udp
    /// OSC 1.0 stream framing: 4-byte big-endian length, then the packet.
    case tcpLengthPrefixed
    /// OSC 1.1 stream framing: double-END SLIP.
    case tcpSLIP
}
