import Foundation
import Testing
@testable import WilcoCore

@Suite("Marker settings")
struct MarkerSettingsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    @Test func showWithoutMarkersDecodesNil() throws {
        let show = try WilcoJSON.decoder().decode(ShowDocument.self, from: fixture("show-v1.wilco"))
        #expect(show.markers == nil)
        #expect(show.markerSettings == .standard)
    }

    @Test func uneditedShowEncodesWithoutMarkersKey() throws {
        let json = String(decoding: try WilcoJSON.encoder().encode(ShowDocument()), as: UTF8.self)
        #expect(!json.contains("\"markers\""))
    }

    @Test func editedMarkersRoundTrip() throws {
        var show = ShowDocument()
        var settings = MarkerSettings.standard
        settings.labels.append(MarkerLabel(category: .phase, name: "Keynote", phrases: ["keynote"]))
        settings.departments.append("rigging")
        settings.countdownEnabled = false
        show.markers = settings
        let decoded = try WilcoJSON.decoder().decode(ShowDocument.self, from: WilcoJSON.encoder().encode(show))
        #expect(decoded == show)
    }

    @Test func partialMarkerSettingsFillDefaults() throws {
        let data = Data(#"{"departments":["rigging"]}"#.utf8)
        let settings = try WilcoJSON.decoder().decode(MarkerSettings.self, from: data)
        #expect(settings.departments == ["rigging"])
        #expect(settings.labels == [])
        #expect(settings.departmentGosEnabled && settings.countdownEnabled && settings.songStartEnabled)
    }

    @Test func labelWithUnknownCategoryIsSkipped() throws {
        let data = Data(#"""
        {"labels":[
          {"id":"\#(UUID())","category":"pyroCues","name":"X","isEnabled":true,"phrases":["x"]},
          {"id":"\#(UUID())","category":"cue","name":"Hold","isEnabled":true,"phrases":["hold"]}
        ]}
        """#.utf8)
        let settings = try WilcoJSON.decoder().decode(MarkerSettings.self, from: data)
        #expect(settings.labels.map(\.name) == ["Hold"])
    }

    @Test func standardMatchesTheBuiltInLists() {
        let standard = MarkerSettings.standard
        #expect(standard.labels(in: .phase).map(\.name) == [
            "Doors", "Walk-in", "Top of show", "Downbeat", "Blackout", "Curtain",
            "Intermission", "Encore", "Show clear", "Load out",
        ])
        #expect(standard.labels(in: .houseLights).map(\.name) == [
            "House lights out", "House lights at half", "House lights up", "House lights discussed",
        ])
        #expect(standard.labels(in: .song).map(\.name) == ["Playback"])
        #expect(standard.labels(in: .cue).map(\.name) == ["Standby", "Hold"])
        #expect(standard.labels(in: .department).isEmpty)
        #expect(standard.departments.contains("LX") && standard.departments.contains("pyro"))
    }

    @Test func movingLabelsStaysWithinTheirCategory() {
        var settings = MarkerSettings.standard
        // Move "Hold" above "Standby" in Cue calls.
        settings.moveLabels(in: .cue, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(settings.labels(in: .cue).map(\.name) == ["Hold", "Standby"])
        #expect(settings.labels(in: .houseLights).map(\.name) == MarkerSettings.standard.labels(in: .houseLights).map(\.name))
        #expect(settings.labels.count == MarkerSettings.standard.labels.count)
    }

    @Test func movingToTheEndOfACategory() {
        var settings = MarkerSettings.standard
        settings.moveLabels(in: .houseLights, fromOffsets: IndexSet(integer: 0), toOffset: 4)
        #expect(settings.labels(in: .houseLights).map(\.name) == [
            "House lights at half", "House lights up", "House lights discussed", "House lights out",
        ])
    }
}
