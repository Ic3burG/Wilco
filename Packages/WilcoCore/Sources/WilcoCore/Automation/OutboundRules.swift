import Darwin
import Foundation

/// Finds the rules in a show that would send what is heard on comms
/// somewhere else, so a show file from someone else can't quietly stream a
/// crew's comms off the Mac.
///
/// A rule counts when it is on and has a webhook (to any host), or OSC to a
/// destination outside the local network. OSC to consoles on the LAN is what
/// shows are made of, so it stays on.
public enum OutboundRules {
    public struct TurnedOff: Equatable, Sendable {
        public var rule: String
        /// Where the rule sends, in the order its actions name them.
        public var hosts: [String]

        public init(rule: String, hosts: [String]) {
            self.rule = rule
            self.hosts = hosts
        }
    }

    public struct Result: Equatable, Sendable {
        public var show: ShowDocument
        public var turnedOff: [TurnedOff]
    }

    /// The show with every such rule turned off, and what was turned off.
    public static func turningOff(in show: ShowDocument) -> Result {
        var show = show
        var turnedOff: [TurnedOff] = []
        for index in show.rules.indices where show.rules[index].isEnabled {
            let hosts = outboundHosts(of: show.rules[index], in: show)
            guard !hosts.isEmpty else { continue }
            show.rules[index].isEnabled = false
            turnedOff.append(TurnedOff(rule: show.rules[index].name, hosts: hosts))
        }
        return Result(show: show, turnedOff: turnedOff)
    }

    static func outboundHosts(of rule: AutomationRule, in show: ShowDocument) -> [String] {
        var hosts: [String] = []
        for action in rule.actions {
            let host: String?
            switch action {
            case .webhook(let urlTemplate, _, _):
                host = webhookHost(urlTemplate)
            case .osc(let destinationID, _, _):
                host = show.destinations.first { $0.id == destinationID }
                    .map(\.host)
                    .flatMap { isLocalNetwork($0) ? nil : $0 }
            case .midi, .notify, .markCuePoint:
                host = nil
            }
            if let host, !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// The host a webhook template names, or the template itself when it
    /// doesn't parse, so the person still sees where it points.
    private static func webhookHost(_ template: String) -> String {
        let context = TemplateContext(text: "x", channel: "x", keyword: "x", date: .distantPast, offset: 0, voice: "x", rule: "x")
        let url = URL(string: context.expand(template, escaping: .url))
        if let host = url?.host(), !host.isEmpty { return host }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "an unnamed address" : trimmed
    }

    /// Loopback, private and link-local addresses, `.local` names and
    /// single-label names (which only resolve on the local network).
    ///
    /// Addresses are read the way the system resolver reads them
    /// (`inet_aton`, `inet_pton`), so numeric forms such as `134744072`,
    /// `0x08080808` or `010.8.8.8` are judged by the address they really
    /// name, not mistaken for a local name or a private address.
    public static func isLocalNetwork(_ host: String) -> Bool {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains("\u{0}") else { return false }

        if host.contains(":") {
            let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            guard let bytes = ipv6Bytes(address) else { return false }
            return isLocalIPv6(bytes)
        }
        if let address = ipv4(host) { return isLocalIPv4(address) }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        // A single-label name, but only one that names a host rather than
        // a number the resolver might still read as an address.
        return !host.contains(".") && host.contains(where: { $0.isLetter }) && !host.hasPrefix("0x")
    }

    /// The address in host byte order when the resolver would read `host`
    /// as IPv4, in any of the dotted, decimal, octal or hex forms.
    private static func ipv4(_ host: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func isLocalIPv4(_ address: UInt32) -> Bool {
        let a = address >> 24, b = (address >> 16) & 0xFF
        return a == 127 || a == 10
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (a == 169 && b == 254)
    }

    private static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }  // ::1
        // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address inside.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isLocalIPv4(bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        return (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)  // link-local fe80::/10
            || bytes[0] & 0xFE == 0xFC  // unique local fc00::/7
    }
}
