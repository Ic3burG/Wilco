import Foundation
import Testing
@testable import WilcoCore

@Suite("Show store")
struct ShowStoreTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ShowStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var current: URL { directory.appending(path: "Current.wilco") }

    @Test func missingFileStartsANewShow() throws {
        let result = ShowStore(directory: directory).load()
        #expect(result.document == ShowDocument())
        #expect(result.recoveredFileURL == nil)
    }

    @Test func savesAndReloads() throws {
        let store = ShowStore(directory: directory)
        var show = ShowDocument(name: "Tour")
        show.addChannel()

        try store.save(show)

        #expect(store.load().document == show)
    }

    @Test func unreadableFileIsKeptAsideNotOverwritten() throws {
        try Data("{ not json".utf8).write(to: current)

        let result = ShowStore(directory: directory).load()

        #expect(result.document == ShowDocument())
        let kept = try #require(result.recoveredFileURL)
        #expect(kept.lastPathComponent.hasPrefix("Current-unreadable-"))
        #expect(try Data(contentsOf: kept) == Data("{ not json".utf8))
        #expect(FileManager.default.fileExists(atPath: current.path) == false)
    }
}
