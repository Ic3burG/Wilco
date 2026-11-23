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
