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
}
