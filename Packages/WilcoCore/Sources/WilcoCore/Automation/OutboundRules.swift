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
    public static func isLocalNetwork(_ host: String) -> Bool {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        if host.contains(":") { return isLocalIPv6(host) }
        if let octets = ipv4Octets(host) { return isLocalIPv4(octets) }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), (0...255).contains(value) else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    private static func isLocalIPv4(_ o: [Int]) -> Bool {
        o[0] == 127 || o[0] == 10
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        if address == "::1" { return true }
        let first = address.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
        guard let word = UInt16(first, radix: 16) else { return false }
        return word & 0xFFC0 == 0xFE80  // link-local fe80::/10
            || word & 0xFE00 == 0xFC00  // unique local fc00::/7
    }
}
