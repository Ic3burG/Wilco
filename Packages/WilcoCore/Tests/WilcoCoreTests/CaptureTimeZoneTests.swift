import Foundation
import Testing
@testable import WilcoCore

@Suite("Capture time zone")
struct CaptureTimeZoneTests {
    private let phoenix = TimeZone(identifier: "America/Phoenix")!
    private let eastern = TimeZone(identifier: "America/Toronto")!
    /// 2026-11-21 17:20:52 in Phoenix (UTC−7).
    private let start = Date(timeIntervalSince1970: 1_795_306_852)

    private func line(at offset: Double, delay: Double = 2, zone: String? = nil) -> TranscriptSegment {
        var segment = TranscriptSegment(
            channelID: UUID(), text: "Standby", timestamp: start.addingTimeInterval(offset + delay),
            sessionOffset: offset, isFinal: true
        )
        segment.timeZone = zone
        return segment
    }

    private func transcript(in zone: TimeZone) -> URL {
        URL(filePath: "/tmp").appending(path: TranscriptFile.fileName(for: start, timeZone: zone))
    }

    @Test func fileNameIsTheCaptureWallClock() {
        #expect(TranscriptFile.fileName(for: start, timeZone: phoenix) == "Session 2026-11-21 1720-52.jsonl")
    }

    @Test func linesWithoutAZoneStillDecodeAndNewOnesKeepIt() throws {
        let old = #"{"id":"6F1D2E2A-6C55-4C11-9E0B-8C1E0F3C0A11","channelID":"6F1D2E2A-6C55-4C11-9E0B-8C1E0F3C0A12","text":"Go","timestamp":"2026-11-22T00:23:06Z","sessionOffset":134,"isFinal":true,"matchedKeywords":[],"highlights":[]}"#
        let decoded = TranscriptFile.segments(in: Data(old.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].timeZone == nil)

        // Written without a zone, the line is byte-for-byte what it was.
        let plain = String(decoding: try TranscriptFile.line(for: line(at: 0)), as: UTF8.self)
        #expect(!plain.contains("timeZone"))

        let stamped = try TranscriptFile.line(for: line(at: 0, zone: "America/Phoenix"))
        #expect(TranscriptFile.segments(in: stamped).first?.timeZone == "America/Phoenix")
    }

    @Test func writerStampsItsZoneOnEveryLine() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Session.jsonl")
        let writer = TranscriptWriter(url: url, timeZone: phoenix)
        try writer.append(line(at: 0))
        try writer.append(line(at: 5, zone: "Europe/London"))  // a line's own zone wins
        let zones = TranscriptFile.segments(in: try Data(contentsOf: url)).map(\.timeZone)
        #expect(zones == ["America/Phoenix", "Europe/London"])
    }

    @Test func zoneOnTheLinesWins() {
        let zone = CaptureTimeZone.of([line(at: 3, zone: "America/Phoenix")], transcript: transcript(in: eastern))
        #expect(zone?.identifier == "America/Phoenix")
    }

    @Test func olderSessionsGetTheOffsetFromTheFileName() throws {
        let lines = [line(at: 40, delay: 9), line(at: 3, delay: 1.5)]
        let zone = try #require(CaptureTimeZone.of(lines, transcript: transcript(in: phoenix)))
        #expect(zone.secondsFromGMT(for: start) == -7 * 3600)

        let india = TimeZone(identifier: "Asia/Kolkata")!
        #expect(CaptureTimeZone.of(lines, transcript: transcript(in: india))?.secondsFromGMT(for: start) == 19_800)
    }

    @Test func noZoneWhenTheNameDoesNotFit() {
        let lines = [line(at: 3)]
        #expect(CaptureTimeZone.of(lines, transcript: URL(filePath: "/tmp/Rehearsal.jsonl")) == nil)
        #expect(CaptureTimeZone.of(lines, transcript: nil) == nil)
        #expect(CaptureTimeZone.of([], transcript: transcript(in: phoenix)) == nil)
        // A file renamed to a time that isn't near a quarter-hour offset.
        let off = URL(filePath: "/tmp/Session 2026-11-21 1728-00.jsonl")
        #expect(CaptureTimeZone.of(lines, transcript: off) == nil)
    }

    @Test func readsTheZoneFromTheStartOfAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: TranscriptFile.fileName(for: start, timeZone: phoenix))
        var data = Data()
        for offset in stride(from: 3.0, to: 3000, by: 10) { data += try TranscriptFile.line(for: line(at: offset)) }
        try data.write(to: url)
        #expect(CaptureTimeZone.read(transcript: url)?.secondsFromGMT(for: start) == -7 * 3600)
    }

    @Test func clockLabelsOnlyWhenTheZoneDiffers() {
        let away = CaptureClock(capture: phoenix, local: eastern, at: start)
        #expect(away.isLabelled)
        #expect(away.timeZone == phoenix)
        #expect(away.label == "MST")
        #expect(away.note == "Times are Phoenix time (MST), when it was recorded: 2 h behind this Mac.")

        let home = CaptureClock(capture: eastern, local: TimeZone(identifier: "America/New_York")!, at: start)
        #expect(!home.isLabelled)
        #expect(home.note == nil)

        let unknown = CaptureClock(capture: nil, local: eastern, at: start)
        #expect(!unknown.isLabelled)
        #expect(unknown.timeZone == eastern)
    }

    @Test func clockNotesAZoneKnownOnlyByItsOffset() {
        let india = CaptureClock(capture: TimeZone(secondsFromGMT: 19_800), local: eastern, at: start)
        #expect(india.label == "GMT+5:30")
        #expect(india.note == "Times are GMT+5:30, when it was recorded: 10 h 30 min ahead of this Mac.")
    }

    @Test func reportExportUsesTheCaptureZone() {
        let report = ShowReportBuilder.build(
            segments: [line(at: 0, delay: 0, zone: "America/Phoenix")], show: ShowDocument(),
            sourceName: "Session.jsonl", generated: start, transcript: nil
        )
        #expect(report.timeZone?.identifier == "America/Phoenix")
        func clock(_ zone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("jmmss")
            return formatter.string(from: start)
        }
        let html = ShowReportHTML.render(report, localTimeZone: eastern)
        #expect(html.contains("<b>\(clock(phoenix)) MST</b>"))
        #expect(!html.contains(clock(eastern)))
        #expect(html.contains("Times are Phoenix time (MST)"))

        let atHome = ShowReportHTML.render(report, localTimeZone: phoenix)
        #expect(atHome.contains("<b>\(clock(phoenix))</b>"))
        #expect(!atHome.contains("Phoenix time"))
    }
}

@Suite("Capture time zone in history")
struct CaptureTimeZoneHistoryTests {
    @Test func summaryStartIsTheTrueMomentWhereverItIsRead() throws {
        let phoenix = TimeZone(identifier: "America/Phoenix")!
        let start = Date(timeIntervalSince1970: 1_795_306_852)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: TranscriptFile.fileName(for: start, timeZone: phoenix))
        // An older file: no zone on the line.
        let line = TranscriptSegment(channelID: UUID(), text: "Go", timestamp: start.addingTimeInterval(4),
                                     sessionOffset: 2, isFinal: true)
        try TranscriptFile.line(for: line).write(to: url)

        let summary = try SessionHistory.summary(transcript: url, candidates: [])
        #expect(summary.started == start)
        #expect(summary.timeZone?.secondsFromGMT(for: start) == -7 * 3600)
    }
}
