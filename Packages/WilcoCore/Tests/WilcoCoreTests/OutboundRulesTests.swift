import Foundation
import Testing
@testable import WilcoCore

@Suite("Imported rules that send elsewhere")
struct OutboundRulesTests {
    private func show(destinationHost: String = "192.168.1.20", rules: (UUID) -> [AutomationRule]) -> ShowDocument {
        var show = ShowDocument(name: "Shared")
        let destination = OSCDestination(name: "Console", host: destinationHost, port: 8000)
        show.destinations = [destination]
        show.rules = rules(destination.id)
        return show
    }

    @Test func webhookRulesArriveOffWithTheirHost() {
        let original = show { _ in
            [AutomationRule(name: "Everything", phrases: [".*"], matchMode: .regularExpression,
                            actions: [.webhook(urlTemplate: "https://collect.example.com/in?t={text}", method: "POST", bodyTemplate: "")])]
        }

        let result = OutboundRules.turningOff(in: original)

        #expect(result.show.rules[0].isEnabled == false)
        #expect(result.turnedOff == [.init(rule: "Everything", hosts: ["collect.example.com"])])
    }

    @Test func localWebhooksAreTurnedOffToo() {
        let original = show { _ in
            [AutomationRule(name: "Local", phrases: ["go"],
                            actions: [.webhook(urlTemplate: "http://127.0.0.1:8080/wilco", method: "POST", bodyTemplate: "")])]
        }
        let result = OutboundRules.turningOff(in: original)
        #expect(result.show.rules[0].isEnabled == false)
        #expect(result.turnedOff.map(\.hosts) == [["127.0.0.1"]])
    }

    @Test func oscToTheLocalNetworkStaysOn() {
        let original = show(destinationHost: "192.168.1.20") { id in
            [AutomationRule(name: "Lights GO", phrases: ["go"], actions: [.osc(destinationID: id, address: "/go", arguments: [])])]
        }
        let result = OutboundRules.turningOff(in: original)
        #expect(result.show == original)
        #expect(result.turnedOff.isEmpty)
    }

    @Test func oscBeyondTheLocalNetworkIsTurnedOff() {
        let original = show(destinationHost: "203.0.113.5") { id in
            [AutomationRule(name: "Relay", phrases: ["go"], actions: [.osc(destinationID: id, address: "/t", arguments: [.string("{text}")])])]
        }
        let result = OutboundRules.turningOff(in: original)
        #expect(result.show.rules[0].isEnabled == false)
        #expect(result.turnedOff == [.init(rule: "Relay", hosts: ["203.0.113.5"])])
    }

    @Test func otherRulesAndRulesAlreadyOffAreLeftAlone() {
        let original = show { _ in
            [
                AutomationRule(name: "MIDI", phrases: ["go"], actions: [.midi(endpointID: 1, message: .programChange(channel: 1, program: 2))]),
                AutomationRule(name: "Mark", phrases: ["go"], actions: [.markCuePoint(label: "GO")]),
                AutomationRule(name: "Off", isEnabled: false, phrases: ["go"],
                               actions: [.webhook(urlTemplate: "https://example.com", method: "POST", bodyTemplate: "")]),
            ]
        }
        let result = OutboundRules.turningOff(in: original)
        #expect(result.show == original)
        #expect(result.turnedOff.isEmpty)
    }

    @Test(arguments: [
        "localhost", "127.0.0.1", "127.8.9.10", "10.0.0.4", "172.16.0.1", "172.31.255.2", "192.168.0.10",
        "169.254.3.4", "console.local", "console.local.", "lx-desk", "::1", "[::1]", "fe80::1", "fd12:3456::1",
    ])
    func localHosts(_ host: String) {
        #expect(OutboundRules.isLocalNetwork(host))
    }

    @Test(arguments: [
        "203.0.113.5", "8.8.8.8", "172.32.0.1", "192.169.0.1", "example.com", "console.lan.example.org",
        "2001:db8::1", "", "  ",
    ])
    func remoteHosts(_ host: String) {
        #expect(!OutboundRules.isLocalNetwork(host))
    }
}
