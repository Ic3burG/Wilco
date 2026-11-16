import Foundation
import Testing
@testable import WilcoCore

@Suite("Report voice letters")
struct ReportVoiceTests {
    private let start = Date(timeIntervalSince1970: 1_794_100_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// Dates and clock times follow the Mac's locale, so blank them before comparing.
    private func withoutLocaleText(_ html: String) -> String {
        var html = html
        for (pattern, template) in [
            (#"<td class="time"><b>[^<]*</b>"#, #"<td class="time"><b></b>"#),
            (#"<title>[^<]*</title>"#, "<title></title>"),
            (#"<h1>([^<]*) <span>[^<]*</span>"#, "<h1>$1 <span></span>"),
        ] {
            html = html.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return html
    }

    @Test func olderTranscriptRendersAsBefore() throws {
        let segments = TranscriptFile.segments(in: try fixture("session-v1.jsonl"))
        let report = ShowReportBuilder.build(
            segments: segments, show: ShowDocument(name: "Fixture Show"), sourceName: "session-v1.jsonl",
            generated: Date(timeIntervalSince1970: 1_794_110_000)
        )
        func expected(_ name: String) throws -> String { String(decoding: try fixture(name), as: UTF8.self) }
        let html = ShowReportHTML.render(report, timeZone: TimeZone(identifier: "UTC")!)
        #expect(withoutLocaleText(html) == withoutLocaleText(try expected("report-v1.html")))
        #expect(SubtitleExport.render(report, format: .srt) == (try expected("report-v1.srt")))
        #expect(SubtitleExport.render(report, format: .vtt) == (try expected("report-v1.vtt")))
    }

    @Test func mixedSessionRendersLettersOnlyWhereSet() throws {
        var show = ShowDocument(name: "Mixed")
        let sm = show.addChannel(), lx = show.addChannel()
        show.updateChannel(id: sm.id) { $0.name = "SM" }
        show.updateChannel(id: lx.id) { $0.name = "LX" }
        func line(_ channel: UUID, _ text: String, at offset: Double, voice: String? = nil, exchange: Int? = nil) -> TranscriptSegment {
            TranscriptSegment(channelID: channel, text: text, timestamp: start.addingTimeInterval(offset), sessionOffset: offset,
                              isFinal: true, voice: voice, exchange: exchange)
        }
        let segments = [
            line(sm.id, "Standby lighting", at: 1, voice: "A", exchange: 1),
            line(sm.id, "Lighting standing by", at: 6, voice: "B", exchange: 1),
            line(sm.id, "Copy", at: 12, exchange: 1),  // analysed, voice unknown
            line(lx.id, "Plain channel line", at: 20),  // no voice information
        ]
        let report = ShowReportBuilder.build(segments: segments, show: show, sourceName: "S.jsonl", generated: start)
        #expect(report.messages.map(\.voice) == ["A", "B", nil, nil])

        let html = ShowReportHTML.render(report, timeZone: TimeZone(identifier: "UTC")!)
        #expect(html.contains(#"class="voice">B<"#) && html.contains(#"class="voice">A<"#))
        #expect(html.components(separatedBy: #"class="voice">"#).count - 1 == 2)
        // The page chrome has its own "·"; the lines themselves must not.
        let log = try #require(html.components(separatedBy: #"<table class="rows log">"#).last?.components(separatedBy: "</table>").first)
        #expect(!log.contains("nil") && !log.contains("·"))

        let srt = SubtitleExport.render(report, format: .srt)
        #expect(srt.contains("\nSM: B: Lighting standing by\n"))
        #expect(srt.contains("\nSM: Copy\n"))
        #expect(srt.contains("\nLX: Plain channel line\n"))
        #expect(!srt.contains("nil") && !srt.contains("·"))
        let vtt = SubtitleExport.render(report, format: .vtt)
        #expect(vtt.contains("\nSM: A: Standby lighting\n") && vtt.contains("\nLX: Plain channel line\n"))
    }

    @Test func letterIsEscapedLikeAnyOtherText() {
        #expect(ShowReportHTML.voiceBadge("<B>") == #" <span class="voice">&lt;B&gt;</span>"#)
        #expect(ShowReportHTML.voiceBadge(nil) == "")
    }
}
