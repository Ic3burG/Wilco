import Foundation
import Testing
@testable import WilcoCore

@Suite("Run-of-show markers")
struct MarkerDetectorTests {
    private func labels(_ text: String) -> [String] {
        MarkerDetector.detect(in: text).map { "\($0.category.rawValue):\($0.label)" }
    }

    @Test func recognisesEachCategory() {
        #expect(labels("Doors are open, everyone") == ["phase:Doors"])
        #expect(labels("Kill the house please") == ["houseLights:House lights out"])
        #expect(labels("Houselights to half") == ["houseLights:House lights at half"])
        #expect(labels("Track is rolling") == ["song:Playback"])
        #expect(labels("Going into the next song") == ["song:Song start"])
        #expect(labels("Stand by pyro") == ["cue:Standby"])
        #expect(labels("Pyro go!") == ["department:Pyro go"])
        #expect(labels("We're 5 minutes to doors") == ["phase:Countdown"])
        #expect(labels("Ten minutes until top of show") == ["phase:Top of show"])
        #expect(labels("We are at 5 minutes to") == ["phase:Countdown"])
    }

    @Test func oneLineCanMarkSeveralCategories() {
        #expect(labels("Standby house lights out") == ["houseLights:House lights out", "cue:Standby"])
    }

    @Test func mentioningHouseLightsIsTheLeastSpecificMatch() {
        #expect(labels("What are the house lights doing?") == ["houseLights:House lights discussed"])
    }

    @Test func ordinaryChatterMarksNothing() {
        #expect(labels("Can someone grab me a coffee") == [])
    }
}

@Suite("Show report")
struct ShowReportBuilderTests {
    private let start = Date(timeIntervalSince1970: 1_794_100_000)

    private func line(_ channel: UUID, _ text: String, at offset: Double) -> TranscriptSegment {
        TranscriptSegment(channelID: channel, text: text, timestamp: start.addingTimeInterval(offset),
                          sessionOffset: offset, isFinal: true, confidence: 0.9)
    }

    private func build() -> (ShowReport, ChannelConfig, ChannelConfig) {
        var show = ShowDocument(name: "Tour Night 1")
        let sm = show.addChannel(), lx = show.addChannel()
        show.updateChannel(id: sm.id) { $0.name = "Stage Manager" }
        show.updateChannel(id: lx.id) { $0.name = "Lighting" }
        let segments = [
            line(sm.id, "Standby lighting cue five", at: 10),
            line(sm.id, "Standby lighting cue five", at: 30),
            line(lx.id, "Standing by, standing by", at: 32),
            line(sm.id, "Lighting go", at: 40),
            line(sm.id, "Standby again", at: 200),
            line(UUID(), "From a deleted channel", at: 250),
        ]
        let report = ShowReportBuilder.build(segments: segments, show: show, sourceName: "Session.jsonl", generated: start)
        return (report, show.channels[0], show.channels[1])
    }

    @Test func summarisesTheSession() {
        let (report, _, _) = build()
        #expect(report.showName == "Tour Night 1")
        #expect(report.sessionStart == start)
        #expect(report.duration == 240)
        #expect(report.totalMessages == 6)
        #expect(report.messages.map(\.channelName).last == "Unknown channel")
    }

    @Test func repeatedCallsCollapseIntoOneMarker() {
        let (report, sm, _) = build()
        let standbys = report.markers.filter { $0.label == "Standby" && $0.channelID == sm.id }
        #expect(standbys.map(\.repeats) == [2, 1])
        #expect(standbys.first?.elapsed == 10)
        #expect(report.markers.contains { $0.category == .department && $0.label == "Lighting go" })
    }

    @Test func countsMessagesWordsAndTopTermsPerChannel() throws {
        let (report, sm, lx) = build()
        let stage = try #require(report.channels.first { $0.id == sm.id })
        #expect(stage.messages == 4)
        #expect(stage.words == 12)
        // Ties sort alphabetically; words under three letters ("go") are skipped.
        #expect(stage.topTerms.prefix(2) == [ShowReport.Term(word: "lighting", count: 3), ShowReport.Term(word: "standby", count: 3)])
        #expect(!stage.topTerms.contains { $0.word == "go" })
        let lighting = try #require(report.channels.first { $0.id == lx.id })
        #expect(lighting.topTerms.first?.word == "standing")
    }

    @Test func bucketsCoverTheWholeSession() {
        let (report, _, _) = build()
        let total = report.buckets.reduce(0) { $0 + $1.counts.values.reduce(0, +) }
        #expect(total == 6)
        #expect(report.buckets.first?.start == 0)
        #expect(report.bucketSeconds >= 60)
    }

    @Test func searchMatchesEveryWordAnywhereInTheLine() {
        let (report, sm, _) = build()
        #expect(ShowReportSearch.messages(in: report, matching: "cue five").count == 2)
        #expect(ShowReportSearch.messages(in: report, matching: "STANDBY", channels: [sm.id]).count == 3)
        #expect(ShowReportSearch.messages(in: report, matching: "").count == 6)
    }
}

@Suite("Report export")
struct ReportExportTests {
    private func report() -> ShowReport {
        var show = ShowDocument(name: #"Tour <Night> & "Day""#)
        let channel = show.addChannel()
        show.updateChannel(id: channel.id) { $0.name = "SM" }
        let start = Date(timeIntervalSince1970: 1_794_100_000)
        let segments = [
            TranscriptSegment(channelID: channel.id, text: "Standby <LX>", timestamp: start.addingTimeInterval(1.5), sessionOffset: 1.5, isFinal: true),
            TranscriptSegment(channelID: channel.id, text: "LX go", timestamp: start.addingTimeInterval(3_725.25), sessionOffset: 3_725.25, isFinal: true),
        ]
        return ShowReportBuilder.build(segments: segments, show: show, sourceName: "S.jsonl", generated: start)
    }

    @Test func srtNumbersCuesWithCommaMilliseconds() {
        let srt = SubtitleExport.render(report(), format: .srt)
        #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:05,500\nSM: Standby <LX>\n\n2\n01:02:05,250 --> 01:02:09,250\nSM: LX go\n"))
    }

    @Test func vttHasAHeaderAndDotMilliseconds() {
        let vtt = SubtitleExport.render(report(), format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:05.500\nSM: Standby &lt;LX&gt;\n"))
    }

    @Test func htmlEscapesEverythingFromTheSession() {
        let html = ShowReportHTML.render(report())
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("Tour &lt;Night&gt; &amp; &quot;Day&quot;"))
        #expect(html.contains("Standby &lt;LX&gt;"))
        #expect(!html.contains("<LX>"))
        #expect(html.contains(#"data-tab="run""#) && html.contains(#"data-tab="log""#) && html.contains(#"data-tab="channels""#))
    }

    @Test func htmlMarksTheCallWithoutBreakingEscaping() {
        #expect(ShowReportHTML.marked("Stand by <LX>, standby & go", phrase: "stand by")
            == #"<mark class="call">Stand by</mark> &lt;LX&gt;, <mark class="call">standby</mark> &amp; go"#)
        #expect(ShowReportHTML.marked("<b>nothing</b>", phrase: "standby") == "&lt;b&gt;nothing&lt;/b&gt;")
    }

    @Test func htmlCarriesTheWindowsChannelStatsAndTraffic() {
        let report = report()
        let html = ShowReportHTML.render(report, timeZone: TimeZone(identifier: "UTC")!)
        #expect(html.contains("Messages per channel") && html.contains("busiest 0:00:01"))
        #expect(html.contains(#"class="heat""#))
        for channel in report.channels { #expect(html.contains(#"data-ch="\#(channel.id)""#)) }
        // One column per bucket in each channel's traffic row.
        let firstRow = html.components(separatedBy: #"<div class="cols">"#)[1].components(separatedBy: "</div>")[0]
        #expect(firstRow.components(separatedBy: "<i").count - 1 == report.buckets.count)
    }
}

/// Builds reports from the real sessions on this Mac, when there are any.
@Suite("Live sessions", .enabled(if: FileManager.default.fileExists(atPath: DataLocations.transcripts.path)))
struct LiveSessionReportTests {
    @Test func everySessionOnThisMacBuildsAReport() throws {
        let show = (try? Data(contentsOf: DataLocations.root.appending(path: ShowFile.currentName)))
            .flatMap { try? WilcoJSON.decoder().decode(ShowDocument.self, from: $0) } ?? ShowDocument()
        let files = try FileManager.default.contentsOfDirectory(at: DataLocations.transcripts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        for file in files {
            let segments = TranscriptFile.segments(in: try Data(contentsOf: file))
            let start = Date()
            let report = ShowReportBuilder.build(segments: segments, show: show, sourceName: file.lastPathComponent, generated: .now)
            let seconds = Date().timeIntervalSince(start)
            #expect(report.totalMessages == segments.count)
            // A budget that grows with the session: an overnight 7,800-line
            // session takes ~3 s, which is fine; a slowdown per line is not.
            let budget = max(2, Double(segments.count) / 1_000)
            #expect(seconds < budget, "\(file.lastPathComponent) took \(seconds) s, budget \(budget) s")
            let byCategory = Dictionary(grouping: report.markers, by: \.category).mapValues(\.count)
            // WILCO_EXPORT_DIR=/some/folder writes each session's HTML there to look at.
            if let folder = ProcessInfo.processInfo.environment["WILCO_EXPORT_DIR"] {
                let url = URL(filePath: folder).appending(path: file.deletingPathExtension().lastPathComponent + ".html")
                try ShowReportHTML.render(report).write(to: url, atomically: true, encoding: .utf8)
            }
            print("REPORT \(file.lastPathComponent): \(report.totalMessages) lines, \(Int(report.duration / 60)) min, markers \(byCategory.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")), \(String(format: "%.2f", seconds)) s")
        }
    }

    @Test func phrasesAreFoundHoweverTheyAreSpaced() {
        let text = "Stand by, Pyro stand-by. Standby for the standbys."
        let found = PhraseLocator.ranges(of: "stand by", in: text).map { String(text[$0]) }
        #expect(found == ["Stand by", "stand-by", "Standby"])
        #expect(PhraseLocator.ranges(of: "all clear", in: "All clear, all clear.").count == 2)
        // The call as one word still finds it said as two.
        #expect(PhraseLocator.ranges(of: "standby", in: "Stand by, touch the sky").map { String("Stand by, touch the sky"[$0]) } == ["Stand by"])
        #expect(PhraseLocator.ranges(of: "house lights", in: "go houselights").count == 1)
        #expect(PhraseLocator.ranges(of: "go", in: "Lighting go, going, gobo").count == 1)
        #expect(PhraseLocator.ranges(of: "  ", in: "anything").isEmpty)
        #expect(PhraseLocator.ranges(of: "q5.", in: "cue q5 go").count == 1)
    }

    @Test func queriesSeparateWordsFromQuotedPhrases() {
        let query = ShowReportSearch.Query(#"lights "top of  the show" go"#)
        #expect(query.words == ["lights", "go"])
        #expect(query.phrases == ["top of the show"])
        #expect(query.matches("Go house lights at the top of the show"))
        #expect(!query.matches("Go house lights at the top of show"))
        #expect(ShowReportSearch.Query(#""unterminated phrase"#).phrases == ["unterminated phrase"])
        #expect(ShowReportSearch.Query(#"  ""  "#).isEmpty)
        // Loose words still match inside longer ones; phrases need whole words.
        #expect(ShowReportSearch.Query("stand").matches("Standby"))
        #expect(!ShowReportSearch.Query(#""stand""#).matches("Standby"))
    }

    @Test func busiestWindowStartsAtALineAndPrefersTheEarliest() {
        #expect(ShowReportBuilder.busiestWindow(in: []) == nil)
        let found = ShowReportBuilder.busiestWindow(in: [0, 100, 700, 750, 800, 1000, 1500])
        #expect(found?.start == 700 && found?.count == 4)
        let tie = ShowReportBuilder.busiestWindow(in: [0, 10, 2000, 2010])
        #expect(tie?.start == 0 && tie?.count == 2)
    }

    @Test func termsKeepApostrophesAndDropChatter() {
        #expect(ShowReportBuilder.terms(in: "He’s ready, let's go. It's 2024; don't PYRO pyro") == ["he's", "ready", "let's", "pyro", "pyro"])
        #expect(ShowReportBuilder.terms(in: "'cause 'em") == ["'cause"])
    }
}

@Suite("Report groups")
struct ReportGroupTests {
    private let start = Date(timeIntervalSince1970: 1_794_100_000)

    /// Radios = C (speaks) and D (silent); Stage = A (silent); B ungrouped speaks.
    private func build(radiosName: String = "Radios") -> (ShowReport, GroupedShow) {
        var f = GroupedShow()
        f.show.renameGroup(id: f.radios.id, to: radiosName)
        let segments = [f.c, f.b, f.c].enumerated().map { index, channel in
            TranscriptSegment(channelID: channel.id, text: "Line \(index)", timestamp: start.addingTimeInterval(Double(index)),
                              sessionOffset: Double(index), isFinal: true, confidence: 0.9)
        }
        return (ShowReportBuilder.build(segments: segments, show: f.show, sourceName: "S.jsonl", generated: start), f)
    }

    @Test func reportGroupsFollowCurrentShowAndSkipSilentChannels() {
        let (report, f) = build()
        #expect(report.groups.map(\.id) == [f.radios.id])
        #expect(report.groups.first?.channelIDs == [f.c.id])
        #expect(report.groups.first?.name == "Radios")
    }

    @Test func groupChipTogglesAllItsChannels() {
        let f = GroupedShow()
        let group = ShowReport.Group(id: f.radios.id, name: "Radios", symbol: "folder", channelIDs: [f.c.id, f.d.id])
        #expect(group.toggled([]) == [f.c.id, f.d.id])
        #expect(group.toggled([f.c.id, f.d.id, f.a.id]) == [f.a.id])
        #expect(group.toggled([f.c.id]) == [f.c.id, f.d.id])
        #expect(group.isOn(in: [f.c.id, f.d.id]))
        #expect(!group.isOn(in: [f.c.id]))
        #expect(!group.isOn(in: []))
    }

    @Test func htmlHasGroupChipsWithMemberIDsAndEscapesNames() {
        let (report, f) = build(radiosName: #"Rad<i>os & "Co""#)
        let html = ShowReportHTML.render(report)
        #expect(html.contains(#"data-group="\#(f.c.id)""#))
        #expect(html.contains("Rad&lt;i&gt;os &amp; &quot;Co&quot;"))
        #expect(!html.contains("Rad<i>os"))
    }
}
