import Foundation
import Testing
@testable import WilcoCore

@Suite("Configuration store")
struct ConfigurationStoreTests {
    private let directory: URL
    private let store: ConfigurationStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ConfigurationStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = ConfigurationStore(directory: directory)
    }

    private func show(_ name: String, channels: Int = 0) -> ShowDocument {
        var show = ShowDocument(name: name)
        for _ in 0..<channels { show.addChannel() }
        return show
    }

    @Test func createListsByNameWithChannelCount() throws {
        try store.create(show("Theatre", channels: 2))
        try store.create(show("Arena"))

        let list = store.list()
        #expect(list.map(\.name) == ["Arena", "Theatre"])
        #expect(list.last?.channelCount == 2)
    }

    @Test func createUniquesNames() throws {
        try store.create(show("Arena"))
        try store.create(show("Arena"))
        try store.create(show("arena"))

        #expect(Set(store.list().map(\.name)) == ["Arena", "Arena 2", "arena 3"])
    }

    @Test func writeOverwritesAndDocumentReads() throws {
        let id = try store.create(show("Arena", channels: 1))
        var edited = try store.document(id)
        edited.channels[0].name = "Changed"

        try store.write(edited, id: id)

        #expect(try store.document(id) == edited)
    }

    @Test func renameRejectsEmptyAndTaken() throws {
        try store.create(show("Arena"))
        let id = try store.create(show("Theatre"))

        #expect(throws: ConfigurationError.emptyName) { try store.rename(id, to: "  ") }
        #expect(throws: ConfigurationError.nameTaken("Arena")) { try store.rename(id, to: "ARENA") }
        let renamed = try store.rename(id, to: " Stadium ")
        #expect(renamed.name == "Stadium")
        #expect(try store.document(id).name == "Stadium")
    }

    @Test func renameToOwnNameDifferentCaseIsAllowed() throws {
        let id = try store.create(show("Arena"))
        #expect(try store.rename(id, to: "ARENA").name == "ARENA")
    }

    @Test func duplicateAddsCopy() throws {
        let id = try store.create(show("Arena", channels: 2))
        let first = try store.duplicate(id)
        let second = try store.duplicate(id)

        #expect(try store.document(first).name == "Arena copy")
        #expect(try store.document(second).name == "Arena copy 2")
        var copy = try store.document(first)
        copy.name = "Arena"
        #expect(copy == (try store.document(id)))
    }

    @Test func deleteRemovesFile() throws {
        let id = try store.create(show("Arena"))
        try store.delete(id)

        #expect(store.exists(id) == false)
        #expect(throws: ConfigurationError.notFound) { try store.document(id) }
    }

    @Test func listSkipsJunk() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = directory.appending(path: "\(UUID().uuidString).wilco")
        let notUUID = directory.appending(path: "notauuid.wilco")
        let dsStore = directory.appending(path: ".DS_Store")
        try Data("{ nope".utf8).write(to: junk)
        try WilcoJSON.encoder().encode(show("Valid")).write(to: notUUID)
        try Data().write(to: dsStore)

        #expect(store.list().isEmpty)
        for url in [junk, notUUID, dsStore] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func listOnMissingFolderIsEmpty() {
        #expect(store.list().isEmpty)
    }

    // MARK: Import, export, migration

    private func outsideFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wilco")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func importsFormatV1Fixture() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/show-v1.wilco", withExtension: nil))
        let expected = try WilcoJSON.decoder().decode(ShowDocument.self, from: Data(contentsOf: url))

        let result = store.importFiles([url])

        #expect(result.failed.isEmpty)
        let id = try #require(result.imported.first)
        #expect(try store.document(id) == expected)
    }

    @Test func importKeepsGoodFilesAndReportsBad() throws {
        let good = try outsideFile(#"{"name":"Good"}"#)
        let bad = try outsideFile("{ nope")

        let result = store.importFiles([good, bad])

        #expect(result.imported.count == 1)
        #expect(result.failed == [bad])
    }

    @Test func importBlankNameBecomesNewShow() throws {
        let result = store.importFiles([try outsideFile(#"{"name":"  "}"#)])
        let id = try #require(result.imported.first)
        #expect(try store.document(id).name == "New Show")
    }

    @Test func importClashGetsNumber() throws {
        try store.create(show("Arena"))
        let result = store.importFiles([try outsideFile(#"{"name":"Arena"}"#)])
        let id = try #require(result.imported.first)
        #expect(try store.document(id).name == "Arena 2")
    }

    @Test func exportRoundTrips() throws {
        let id = try store.create(show("Arena", channels: 3))
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wilco")

        try store.export(id, to: url)

        #expect(try WilcoJSON.decoder().decode(ShowDocument.self, from: Data(contentsOf: url)) == store.document(id))
    }

    @Test func migrateCreatesFromCurrentOnce() throws {
        let current = show("Tour", channels: 1)
        let id = try #require(try store.migrateIfEmpty(from: current))
        #expect(try store.document(id) == current)

        #expect(try store.migrateIfEmpty(from: show("Other")) == nil)
        #expect(store.list().count == 1)
    }

    @Test func migrateIgnoresJunkOnlyFolder() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: directory.appending(path: "\(UUID().uuidString).wilco"))

        #expect(try store.migrateIfEmpty(from: show("Tour")) != nil)
        #expect(store.list().map(\.name) == ["Tour"])
    }
}
