import Foundation
import Testing
@testable import WilcoCore

@Suite("Session retention")
struct SessionRetentionTests {
    typealias Retention = SessionRetention

    /// A Transcripts folder and a stand-in Trash, so tests never touch the
    /// real one.
    struct Folders {
        let transcripts: URL
        let trash: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "retention-\(UUID().uuidString)")
            transcripts = base.appending(path: "Transcripts")
            trash = base.appending(path: "Trash")
            try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        var mover: Retention.Trash {
            let trash = trash
            return { url in try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent)) }
        }

        func write(_ name: String, _ text: String = "x") throws {
            try Data(text.utf8).write(to: transcripts.appending(path: name))
        }

        func folder(_ name: String) throws {
            let url = transcripts.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appending(path: "clips.json"))
        }

        func names(in url: URL) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        }
    }

    /// 2026-11-25 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_608_000)

    @Test func periodDefaultsToKeepingEverything() {
        #expect(Retention.Period.restored(from: nil) == .never)
        #expect(Retention.Period.restored(from: "forever and ever") == .never)
        #expect(Retention.Period.restored(from: "days90") == .days90)
        #expect(Retention.Period.never.days == nil)
        #expect(Retention.Period.year.days == 365)
    }

    @Test(arguments: [
        "Session 2026-11-01 1720-04.jsonl", "Session 2026-11-01 1720-04.wilco",
        "Session 2026-11-01 1720-04.diagnostics", "Session 2026-11-01 1720-04.clips",
        // A time some zones skip at the start of daylight saving.
        "Session 2026-03-08 0230-00.jsonl",
    ])
    func acceptsSessionNames(_ name: String) {
        #expect(Retention.session(forFileName: name) != nil)
    }

    @Test(arguments: [
        "Current.wilco", "Session .jsonl", "Session junk.jsonl", "session 2026-11-01 1720-04.jsonl",
        "Session 2026-13-01 1720-04.jsonl", "Session 2026-11-31 1720-04.jsonl", "Session 2026-1-1 1720-04.jsonl",
        "Session 2026-11-01 2520-04.jsonl", "Session 2026-11-01 1720-04 copy.jsonl", "Session 2026-11-01 1720-04.txt",
        "Session 2026-11-01 1720-04.jsonl.bak", "Session 2026-11-01 1720-04", "xSession 2026-11-01 1720-04.jsonl",
        "Session ../2026-11-01 1720-04.jsonl", "../Session 2026-11-01 1720-04.jsonl", "Session 2026-11-01 1720-04/.jsonl",
        "Session 2026-11-01 1720-04.JSONL", "Session ２０２６-11-01 1720-04.jsonl", "",
    ])
    func refusesOtherNames(_ name: String) {
        #expect(Retention.session(forFileName: name) == nil)
    }

    @Test func neverMovesNothing() throws {
        let folders = try Folders()
        try folders.write("Session 2020-01-01 0000-00.jsonl")
        let outcome = Retention.moveExpired(in: folders.transcripts, keepFor: .never, now: Self.now, trash: folders.mover)
        #expect(outcome == .init())
        #expect(try folders.names(in: folders.transcripts) == ["Session 2020-01-01 0000-00.jsonl"])
    }

    @Test func movesEveryPartOfOldSessionsAndNothingElse() throws {
        let folders = try Folders()
        let old = "Session 2026-09-01 1900-00"
        for ext in ["jsonl", "wilco", "diagnostics"] { try folders.write("\(old).\(ext)") }
        try folders.folder("\(old).clips")
        // Only diagnostics left from an older session: still cleaned.
        try folders.write("Session 2026-08-01 1900-00.diagnostics")
        // Kept: recent, or not Wilco's.
        let recent = "Session 2026-11-20 1900-00"
        try folders.write("\(recent).jsonl")
        try folders.folder("\(recent).clips")
        try folders.write("Session junk.jsonl")
        try folders.write("notes.txt")

        let outcome = Retention.moveExpired(in: folders.transcripts, keepFor: .days30, now: Self.now, trash: folders.mover)

        #expect(outcome == .init(moved: 2, failed: []))
        #expect(try folders.names(in: folders.transcripts) == [
            "\(recent).jsonl", "\(recent).clips", "Session junk.jsonl", "notes.txt",
        ])
        #expect(try folders.names(in: folders.trash) == [
            "\(old).jsonl", "\(old).wilco", "\(old).diagnostics", "\(old).clips",
            "Session 2026-08-01 1900-00.diagnostics",
        ])
    }

    @Test func keepsASessionJustInsideThePeriod() throws {
        let folders = try Folders()
        // 29 days before `now`.
        try folders.write("Session 2026-10-27 1200-00.jsonl")
        #expect(Retention.expired(in: folders.transcripts, keepFor: .days30, now: Self.now).isEmpty)
        #expect(Retention.expired(in: folders.transcripts, keepFor: .days30, now: Self.now.addingTimeInterval(2 * 86_400)).count == 1)
    }

    @Test func aPartThatWontMoveIsReportedAndTheRestGo() throws {
        let folders = try Folders()
        let stuck = "Session 2026-01-01 0000-00"
        try folders.write("\(stuck).jsonl")
        try folders.write("\(stuck).wilco")
        try folders.write("Session 2026-02-01 0000-00.jsonl")
        let mover = folders.mover
        struct Refused: Error {}
        let outcome = Retention.moveExpired(in: folders.transcripts, keepFor: .days90, now: Self.now) { url in
            if url.pathExtension == "wilco" { throw Refused() }
            try mover(url)
        }
        #expect(outcome == .init(moved: 1, failed: [stuck]))
        #expect(try folders.names(in: folders.transcripts) == ["\(stuck).wilco"])
    }

    @Test func aLinkIsMovedNotWhatItPointsTo() throws {
        let folders = try Folders()
        let outside = folders.trash.deletingLastPathComponent().appending(path: "precious.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folders.transcripts.appending(path: "Session 2020-01-01 0000-00.jsonl"), withDestinationURL: outside)

        let outcome = Retention.moveExpired(in: folders.transcripts, keepFor: .days30, now: Self.now, trash: folders.mover)

        #expect(outcome.moved == 1)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    }

    @Test func aMissingFolderIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")
        #expect(Retention.sessions(in: missing).isEmpty)
        #expect(Retention.moveExpired(in: missing, keepFor: .days30, now: Self.now) == .init())
        #expect(Retention.usage(in: missing) == .init(sessions: 0, bytes: 0))
    }

    @Test func usageCountsTranscriptsAndEveryByte() throws {
        let folders = try Folders()
        try folders.write("Session 2026-11-01 1900-00.jsonl", String(repeating: "a", count: 5_000))
        try folders.write("Session 2026-11-01 1900-00.wilco")
        try folders.write("Session 2026-11-02 1900-00.jsonl")
        try folders.folder("Session 2026-11-02 1900-00.clips")
        try folders.write("Session 2026-11-03 1900-00.diagnostics")

        let usage = Retention.usage(in: folders.transcripts)

        #expect(usage.sessions == 2)
        #expect(usage.bytes >= 5_000)
    }
}
