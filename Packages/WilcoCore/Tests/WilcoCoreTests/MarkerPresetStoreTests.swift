import Foundation
import Testing
@testable import WilcoCore

@Suite("Marker preset store")
struct MarkerPresetStoreTests {
    private let directory: URL
    private let store: MarkerPresetStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "MarkerPresetStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = MarkerPresetStore(directory: directory)
    }

    @Test func listIsEmptyBeforeTheFolderExists() {
        #expect(store.list().isEmpty)
    }

    @Test func saveThenListByName() throws {
        var concert = MarkerSettings.standard
        concert.departments.append("rigging")
        try store.save(name: "Theatre", markers: .standard)
        try store.save(name: "Concert", markers: concert)
        #expect(store.list().map(\.name) == ["Concert", "Theatre"])
        #expect(store.list().first?.markers == concert)
    }

    @Test func savingAnExistingNameReplacesItAndKeepsItsID() throws {
        let first = try store.save(name: "Concert", markers: .standard)
        var changed = MarkerSettings.standard
        changed.countdownEnabled = false
        let second = try store.save(name: " concert ", markers: changed)
        #expect(second.id == first.id)
        #expect(store.list().count == 1)
        #expect(try store.preset(first.id).markers == changed)
        #expect(try store.preset(first.id).name == "Concert")
    }

    @Test func emptyNameIsRefused() {
        #expect(throws: ConfigurationError.emptyName) { try store.save(name: "  ", markers: .standard) }
    }

    @Test func renameRefusesTakenAndEmptyNames() throws {
        let concert = try store.save(name: "Concert", markers: .standard)
        try store.save(name: "Theatre", markers: .standard)
        #expect(throws: ConfigurationError.nameTaken("Theatre")) { try store.rename(concert.id, to: "theatre") }
        #expect(throws: ConfigurationError.emptyName) { try store.rename(concert.id, to: "") }
        try store.rename(concert.id, to: "Arena")
        #expect(store.list().map(\.name) == ["Arena", "Theatre"])
        #expect(try store.preset(concert.id).name == "Arena")
    }

    @Test func renamingToItsOwnNameInAnotherCaseIsAllowed() throws {
        let concert = try store.save(name: "concert", markers: .standard)
        #expect(try store.rename(concert.id, to: "Concert").name == "Concert")
    }

    @Test func deleteRemovesAndMissingThrows() throws {
        let concert = try store.save(name: "Concert", markers: .standard)
        try store.delete(concert.id)
        #expect(store.list().isEmpty)
        #expect(throws: ConfigurationError.notFound) { try store.delete(concert.id) }
    }

    @Test func strayAndCorruptFilesAreSkippedAndKept() throws {
        try store.save(name: "Concert", markers: .standard)
        let stray = directory.appending(path: "notes.json")
        let corrupt = directory.appending(path: "\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: stray)
        try Data("not json".utf8).write(to: corrupt)
        #expect(store.list().map(\.name) == ["Concert"])
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test func presetFromANewerBuildStillLoads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let json = #"{"name":"Future","extra":1,"markers":{"labels":[{"id":"\#(UUID().uuidString)","category":"lasers","name":"X","isEnabled":true,"phrases":["x"]}],"departments":["pyro"]}}"#
        try Data(json.utf8).write(to: directory.appending(path: "\(id.uuidString).json"))
        let preset = try store.preset(id)
        #expect(preset.id == id)
        #expect(preset.name == "Future")
        #expect(preset.markers.labels.isEmpty)
        #expect(preset.markers.departments == ["pyro"])
    }
}

@Suite("Built-in marker presets")
struct BuiltInPresetTests {
    private func names(_ text: String, _ settings: MarkerSettings) -> [String] {
        MarkerDetector.detect(in: text, settings: settings).map(\.label)
    }

    @Test func builtInsAreConcertCorporateTheatreWithFixedIDs() {
        #expect(MarkerPreset.builtIn.map(\.name) == ["Concert", "Corporate", "Theatre"])
        #expect(Set(MarkerPreset.builtIn.map(\.id)).count == 3)
        #expect(MarkerPreset.builtIn[0].id == UUID(uuidString: "6F1C2E0A-1C44-4B7E-9C0D-0C0A0C0E0C01"))
    }

    @Test func builtInListsHaveNoDuplicates() {
        for preset in MarkerPreset.builtIn {
            let labelNames = preset.markers.labels.map { "\($0.category.rawValue)|\($0.name.lowercased())" }
            #expect(Set(labelNames).count == labelNames.count, "\(preset.name) label names")
            for label in preset.markers.labels {
                let phrases = label.phrases.map { $0.lowercased() }
                #expect(Set(phrases).count == phrases.count, "\(preset.name) \(label.name)")
            }
            let departments = preset.markers.departments.map { $0.lowercased() }
            #expect(Set(departments).count == departments.count, "\(preset.name) departments")
        }
    }

    @Test func builtInsRoundTrip() throws {
        for preset in MarkerPreset.builtIn {
            let data = try WilcoJSON.encoder().encode(preset.markers)
            #expect(try WilcoJSON.decoder().decode(MarkerSettings.self, from: data) == preset.markers)
        }
    }

    @Test func eachPresetHearsItsKindOfShow() {
        let concert = MarkerPreset.builtIn[0].markers
        let corporate = MarkerPreset.builtIn[1].markers
        let theatre = MarkerPreset.builtIn[2].markers
        #expect(names("Can I get more vocal in my wedge", concert) == ["Monitor request"])
        #expect(names("Check one two, check check", concert) == ["Soundcheck"])
        #expect(names("Changeover, ten minutes", concert) == ["Changeover"])
        #expect(names("Haze go", concert) == ["Haze go"])
        #expect(names("Ladies and gentlemen, this is your half", theatre) == ["Half"])
        #expect(names("Warning LX 47", theatre) == ["Warning"])
        #expect(names("Automation 12 go", theatre) == ["Automation 12 go"])
        #expect(names("Standby VT 2", corporate) == ["Standby"])
        #expect(names("Please welcome to the stage our keynote", corporate) == ["Keynote"])
    }

    @Test func removedLabelsAreGone() {
        #expect(names("Intermission", MarkerPreset.builtIn[0].markers) == [])
        #expect(names("Encore", MarkerPreset.builtIn[1].markers) == [])
        #expect(names("Going into the next song", MarkerPreset.builtIn[1].markers) == [])
    }

    @Test func newLabelsSitWithTheirCategory() {
        let phases = MarkerPreset.builtIn[2].markers.labels(in: .phase).map(\.name)
        #expect(phases.prefix(2) == ["Doors", "Walk-in"])
        #expect(phases.contains("Half"))
        #expect(MarkerPreset.builtIn[0].markers.labels(in: .talkback).map(\.name) == ["Monitor request", "Soundcheck", "Run it again", "Problem"])
    }
}
