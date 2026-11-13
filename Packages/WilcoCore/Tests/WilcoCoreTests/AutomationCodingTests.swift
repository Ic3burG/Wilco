import Foundation
import Testing
@testable import WilcoCore

/// Automation actions use Swift's synthesized enum coding, the format 0.2.0
/// wrote. These pin the JSON shape so a refactor cannot silently change it.
@Suite("Automation JSON shape")
struct AutomationCodingTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try WilcoJSON.encoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func oscActionIsKeyedByCaseName() throws {
        let destination = UUID()
        let action = AutomationAction.osc(
            destinationID: destination,
            address: "/wilco/{channel}/go",
            arguments: [.string("{text}")]
        )
        let osc = try #require(try json(action)["osc"] as? [String: Any])

        #expect(osc["destinationID"] as? String == destination.uuidString)
        #expect(osc["address"] as? String == "/wilco/{channel}/go")
        let argument = try #require((osc["arguments"] as? [[String: Any]])?.first)
        #expect((argument["string"] as? [String: Any])?["_0"] as? String == "{text}")
    }

    @Test func mscGoUsesCueListKey() throws {
        let action = AutomationAction.midi(
            endpointID: 42,
            message: .mscGo(deviceID: 1, cueNumber: "5", cueList: "1")
        )
        let midi = try #require(try json(action)["midi"] as? [String: Any])
        let msc = try #require((midi["message"] as? [String: Any])?["mscGo"] as? [String: Any])

        #expect(midi["endpointID"] as? Int == 42)
        #expect(msc["cueNumber"] as? String == "5")
        #expect(msc["cueList"] as? String == "1")
    }

    @Test func ruleRoundTrips() throws {
        let rule = AutomationRule(
            name: "Vor — Go",
            phrases: ["go"],
            channelIDs: [UUID()],
            cooldown: 3,
            actions: [
                .webhook(urlTemplate: "http://x/{channel}", method: "POST", bodyTemplate: #"{"text":"{text}"}"#),
                .notify(title: "Cue", bodyTemplate: "Heard on {channel}"),
                .markCuePoint(label: "GO"),
            ]
        )
        let data = try WilcoJSON.encoder().encode(rule)
        #expect(try WilcoJSON.decoder().decode(AutomationRule.self, from: data) == rule)
    }
}
