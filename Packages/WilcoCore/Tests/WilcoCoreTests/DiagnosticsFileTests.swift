import Foundation
import Testing
@testable import WilcoCore

@Suite("Diagnostics file")
struct DiagnosticsFileTests {
    private func row(minute: Int = 0, audio: Double = 60, rms: Double? = nil, peak: Double? = nil,
                     cuts: Int? = nil) -> ChannelMinute {
        ChannelMinute(channel: UUID(), minute: minute, audio: audio, sound: 0, rms: rms, peak: peak,
                      floor: nil, clipped: 0, dropped: 0, droppedSeconds: 0, cuts: cuts)
    }

    @Test func urlSitsBesideTranscriptAndIsNotJSONL() {
        let transcript = URL(fileURLWithPath: "/t/Session 2026-11-21 1720-05.jsonl")
        let url = DiagnosticsFile.url(forTranscript: transcript)
        #expect(url.lastPathComponent == "Session 2026-11-21 1720-05.diagnostics")
        #expect(url.pathExtension != "jsonl")
    }

    @Test func roundTripsAndOmitsNils() throws {
        let original = row(minute: 4, peak: -6.5)
        let data = try DiagnosticsFile.line(for: original)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"rms\""))
        #expect(!text.contains("\"utterances\""))
        #expect(!text.contains("\"partial\""))
        #expect(text.contains("\"v\":1"))
        #expect(text.hasSuffix("\n"))
        #expect(DiagnosticsFile.rows(in: data) == [original])
    }

    @Test func partialAndClassifiedRoundTrip() throws {
        var original = row()
        original.partial = true
        original.classified = SoundShares(speech: 0.9, music: 0.05, singing: 0.02)
        let data = try DiagnosticsFile.line(for: original)
        #expect(String(decoding: data, as: UTF8.self).contains("\"partial\":true"))
        #expect(DiagnosticsFile.rows(in: data) == [original])
    }

    @Test func unknownFieldsAndMissingOptionalsDecode() {
        let json = "{\"v\":2,\"channel\":\"\(UUID().uuidString)\",\"minute\":3,\"audio\":60,\"sound\":0,"
            + "\"clipped\":0,\"dropped\":0,\"droppedSeconds\":0,\"future\":true}\n"
        let rows = DiagnosticsFile.rows(in: Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].rms == nil)
        #expect(rows[0].minute == 3)
    }

    @Test func truncatedLastLineIsSkipped() throws {
        var data = try DiagnosticsFile.line(for: row(minute: 0))
        data.append(try DiagnosticsFile.line(for: row(minute: 1)))
        data.append(Data("{\"v\":1,\"chan".utf8))
        #expect(DiagnosticsFile.rows(in: data).map(\.minute) == [0, 1])
    }

    @Test func mergeAddsCountsAndKeepsMaxPeak() {
        var a = row(audio: 20, peak: -10, cuts: 1)
        let b = row(audio: 35, peak: -3, cuts: nil)
        a.merge(b)
        #expect(a.audio == 55)
        #expect(a.peak == -3)
        #expect(a.cuts == 1)
        #expect(a.partial == true)
    }

    @Test func mergeTakesRmsOfLouderSoundMinFloorFirstClassified() {
        var a = row(rms: -30)
        a.sound = 2
        a.floor = -50
        a.classified = SoundShares(speech: 1, music: 0, singing: 0)
        var b = row(rms: -20)
        b.sound = 5
        b.floor = -58
        b.classified = SoundShares(speech: 0, music: 1, singing: 0)
        b.utterances = 3
        a.merge(b)
        #expect(a.rms == -20)
        #expect(a.floor == -58)
        #expect(a.sound == 7)
        #expect(a.utterances == 3)
        #expect(a.classified?.speech == 1)
    }

    @Test func writerCreatesFileOnFirstRowOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Session x.diagnostics")
        let writer = DiagnosticsWriter(url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try writer.append(row(minute: 0))
        try writer.append(row(minute: 1))
        let rows = DiagnosticsFile.rows(in: try Data(contentsOf: url))
        #expect(rows.map(\.minute) == [0, 1])
    }
}
