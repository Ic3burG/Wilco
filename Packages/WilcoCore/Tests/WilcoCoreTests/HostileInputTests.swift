import CryptoKit
import Foundation
import Testing
@testable import WilcoCore

/// Files can be corrupt or written by someone else. Whatever is in them,
/// opening one must never crash the app: Swift traps on out-of-range
/// number conversions and array indexes, and a trap mid-show loses comms.
@Suite("Hostile files never crash")
struct HostileInputTests {
    static let offsets: [Double] = [-5, -1e300, 1e300, 1e18, 9.3e18, 0, 12.5]

    private func transcript(offsets: [Double], confidence: Double? = 0.9) -> Data {
        let channel = UUID()
        var data = Data()
        for (index, offset) in offsets.enumerated() {
            let confidenceField = confidence.map { #","confidence":\#($0)"# } ?? ""
            let line = #"{"id":"\#(UUID().uuidString)","channelID":"\#(channel.uuidString)","text":"Standby LX \#(index), house lights go","timestamp":"2026-11-08T02:25:25Z","sessionOffset":\#(offset),"isFinal":true,"matchedKeywords":[],"highlights":[]\#(confidenceField)}"#
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    @Test(arguments: offsets)
    func reportsSurviveAnyOffset(_ offset: Double) {
        let segments = TranscriptFile.segments(in: transcript(offsets: [1, offset, 30]))
        let report = ShowReportBuilder.build(segments: segments, show: ShowDocument(), sourceName: "x.jsonl", generated: .now)
        _ = ShowReportHTML.render(report, timeZone: .gmt)
        _ = SubtitleExport.render(report, format: .srt)
        _ = SubtitleExport.render(report, format: .vtt)
        _ = ShowReview.make(segments: segments, show: ShowDocument())
        #expect(report.buckets.count <= 200)
    }

    // MARK: Shows

    /// A show file whose IDs repeat and whose numbers are absurd.
    private func hostileShow() throws -> ShowDocument {
        let id = UUID().uuidString, group = UUID().uuidString, rule = UUID().uuidString
        let json = #"""
        {"name":"Hostile","formatVersion":1,
         "channels":[{"id":"\#(id)","name":"A","groupID":"\#(group)","deviceChannel":-9000000000000000000},
                     {"id":"\#(id)","name":"A again","deviceChannel":9000000000000000000}],
         "groups":[{"id":"\#(group)","name":"G","symbol":"folder"},{"id":"\#(group)","name":"G again","symbol":"folder"}],
         "rules":[{"id":"\#(rule)","name":"R","isEnabled":true,"phrases":["go"],"matchMode":"containsAny","channelIDs":[],"cooldown":1e300,"actions":[]},
                  {"id":"\#(rule)","name":"R again","isEnabled":true,"phrases":["go"],"matchMode":"containsAny","channelIDs":[],"cooldown":-1e300,"actions":[]}],
         "voiceChanges":{"threshold":1e300,"exchangeGap":-1e300,"shortLine":1e300},
         "mcpEnabled":true,"networkEnabled":true,"mosEnabled":true}
        """#
        return try WilcoJSON.decoder().decode(ShowDocument.self, from: Data(json.utf8))
    }

    @Test func showsAreRepairedOnDecode() throws {
        let show = try hostileShow()
        #expect(show.channels.count == 1)
        #expect(show.groups.count == 1)
        #expect(show.rules.count == 1)
        #expect(show.rules[0].cooldown == FileLimits.maximumCooldown)
        #expect(show.voiceChanges.threshold == 1)
        #expect(show.voiceChanges.exchangeGap == 0)
        #expect(Int(show.rules[0].cooldown) > 0)  // What the rule editor does.
    }

    @Test func hostileShowsSurviveEditingAndEvaluation() throws {
        var show = try hostileShow()
        let channel = try #require(show.channels.first)
        show.assignChannel(channel.id, toGroup: nil)
        show.assignChannel(channel.id, toGroup: show.groups.first?.id)
        let added = show.addGroup()
        show.moveSidebarItems([.channel(channel.id), .channel(channel.id)], toParent: added.id, at: .max)
        show.deleteGroup(id: added.id)
        var evaluator = AutomationEvaluator()
        _ = evaluator.evaluate(text: "Lights go", channelID: channel.id, in: show, at: .now)
        _ = evaluator.evaluate(text: "Lights go", channelID: channel.id, in: show, at: .now)
        _ = CaptureRouting.plan(
            taps: show.channels.map { CaptureTap(id: $0.id, deviceChannel: $0.deviceChannel ?? 0) },
            bufferChannelCounts: [2, 8]
        )
    }

    @Test func importedShowsCannotSwitchOnSharing() throws {
        let safe = OutboundRules.turningOff(in: try hostileShow()).show
        #expect(!safe.mcpEnabled && !safe.networkEnabled && !safe.mosEnabled)
    }

    // MARK: Diagnostics

    @Test func diagnosticsSurviveAbsurdMinutes() {
        let channel = UUID().uuidString
        let rows = [0, 3, Int.max, Int.min, 9_000_000_000_000_000].map {
            #"{"channel":"\#(channel)","minute":\#($0),"audio":1e300,"sound":-1e300,"clipped":\#(Int.max),"dropped":\#(Int.min),"droppedSeconds":1e300}"#
        }.joined(separator: "\n")
        let parsed = DiagnosticsFile.rows(in: Data(rows.utf8))
        #expect(parsed.allSatisfy { (0...FileLimits.maximumSessionMinutes).contains($0.minute) })
        let diagnostics = SessionDiagnostics.make(parsed)
        let segments = TranscriptFile.segments(in: transcript(offsets: [1, 30]))
        _ = ShowReview.make(segments: segments, show: ShowDocument(), diagnostics: diagnostics)
    }

    // MARK: Audio clips

    @Test func wavDecodingSurvivesTruncationAndLies() {
        let good = WAV.encode([0, 0.5, -0.5, 1], sampleRate: 16_000)
        for cut in 0..<good.count { _ = try? WAV.decode(good.prefix(cut)) }
        // Chunk sizes that claim far more than the file holds.
        for offset in [4, 16, 40] {
            var lying = good
            lying.replaceSubrange(offset..<offset + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
            _ = try? WAV.decode(lying)
        }
    }

    // MARK: Number conversion

    @Test func safeIntNeverTraps() {
        #expect(Int(safely: .nan) == 0)
        #expect(Int(safely: .infinity) == .max)
        #expect(Int(safely: -.infinity) == .min)
        #expect(Int(safely: 1e300) == .max)
        #expect(Int(safely: 9.223372036854775807e18) == .max)
        #expect(Int(safely: -12.9) == -12)
    }

    // MARK: Mutation fuzzing

    /// Deterministic, so a failure can be replayed from the seed in its name.
    private struct Xorshift: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private static let hostileNumbers = [
        "-1", "0", "1e300", "-1e300", "9223372036854775807", "-9223372036854775808", "1e18", "0.0000001", "65536", "4294967296",
    ]

    /// The fixture with some of its numbers swapped for hostile ones, some
    /// values duplicated and, sometimes, bytes flipped.
    private func mutated(_ original: String, using generator: inout Xorshift) -> Data {
        var text = original
        let numbers = text.matches(of: /[:\[,]\s*(-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?)(?=\s*[,}\]])/)
            .map { $0.output.1.startIndex..<$0.output.1.endIndex }
        for range in numbers.reversed() where Int.random(in: 0..<4, using: &generator) == 0 {
            text.replaceSubrange(range, with: Self.hostileNumbers.randomElement(using: &generator)!)
        }
        var bytes = Array(text.utf8)
        if Bool.random(using: &generator), !bytes.isEmpty {
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
        }
        return Data(bytes)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func mutatedShowsNeverCrash() throws {
        let original = try fixture("show-v1.wilco")
        var generator = Xorshift(state: 0x5EED_0001)
        for _ in 0..<400 {
            guard var show = try? WilcoJSON.decoder().decode(ShowDocument.self, from: mutated(original, using: &generator)) else { continue }
            _ = OutboundRules.turningOff(in: show)
            _ = show.sidebarChildren(of: nil)
            if let channel = show.channels.first { show.assignChannel(channel.id, toGroup: show.groups.last?.id) }
            _ = show.addGroup()
            var evaluator = AutomationEvaluator()
            for channel in show.channels.prefix(4) {
                _ = evaluator.evaluate(text: "Standby lights, go", channelID: channel.id, in: show, at: .now)
                _ = AutomationEvaluator.highlights(for: "Standby lights, go", channelID: channel.id, in: show)
            }
            _ = CaptureRouting.plan(
                taps: show.channels.map { CaptureTap(id: $0.id, deviceChannel: $0.deviceChannel ?? 0) },
                bufferChannelCounts: [2, 8]
            )
            _ = try? WilcoJSON.encoder().encode(show)
        }
    }

    @Test func mutatedTranscriptsNeverCrash() throws {
        let original = try fixture("session-v1.jsonl")
        let show = try WilcoJSON.decoder().decode(ShowDocument.self, from: Data(try fixture("show-v1.wilco").utf8))
        var generator = Xorshift(state: 0x5EED_0002)
        for _ in 0..<400 {
            let data = mutated(original, using: &generator)
            let segments = TranscriptFile.segments(in: data)
            let report = ShowReportBuilder.build(segments: segments, show: show, sourceName: "x.jsonl", generated: .now)
            _ = ShowReportHTML.render(report, timeZone: .gmt)
            _ = SubtitleExport.render(report, format: .srt)
            _ = SubtitleExport.render(report, format: .vtt)
            _ = ShowReview.make(segments: segments, show: show, diagnostics: SessionDiagnostics.make(DiagnosticsFile.rows(in: data)))
            _ = CaptureTimeZone.of(segments, transcript: nil)
        }
    }

    // MARK: HTML report

    private static let payloads = [
        "<script>alert(1)</script>", "</title><script>alert(1)</script>", #"" onmouseover="alert(1)"#,
        "<img src=x onerror=alert(1)>", "'><svg onload=alert(1)>", "</style><script>alert(1)</script>",
        "<a href=\"javascript:alert(1)\">x</a>", "--></script><script>alert(1)</script>",
    ]

    /// Every string that reaches the report comes from a show file or from
    /// speech. None of it may become markup.
    @Test(arguments: payloads)
    func reportNeverTurnsTextIntoMarkup(_ payload: String) throws {
        var show = ShowDocument(name: payload)
        show.addChannel()
        show.channels[0].name = payload
        let group = show.addGroup(name: payload)
        show.assignChannel(show.channels[0].id, toGroup: group.id)
        let channel = show.channels[0].id
        let segments = [payload, "Standby LX 5 \(payload)", "House lights go \(payload)"].enumerated().map { index, text in
            TranscriptSegment(channelID: channel, text: text, timestamp: Date(timeIntervalSince1970: 1_794_110_000 + Double(index)),
                              sessionOffset: Double(index), isFinal: true, confidence: 0.4, voice: payload, timeZone: payload)
        }
        let report = ShowReportBuilder.build(segments: segments, show: show, sourceName: payload + ".jsonl", generated: .now)
        let html = ShowReportHTML.render(report, timeZone: .gmt)

        #expect(html.components(separatedBy: "<script").count == 2, "only the report's own script")
        #expect(html.components(separatedBy: "</script>").count == 2)
        #expect(html.components(separatedBy: "</style>").count == 2)
        #expect(html.components(separatedBy: "</title>").count == 2)
        for tag in ["<img", "<svg", "<a href", "<iframe"] { #expect(!html.contains(tag)) }
        #expect(!html.contains(#"" onmouseover=""#))
        #expect(!html.contains("'><"))
    }

    @Test func reportCarriesAContentSecurityPolicyNamingItsScript() throws {
        let report = ShowReportBuilder.build(segments: [], show: ShowDocument(), sourceName: "x.jsonl", generated: .now)
        let html = ShowReportHTML.render(report, timeZone: .gmt)
        let policy = ShowReportHTML.contentSecurityPolicy
        #expect(html.contains(#"<meta http-equiv="Content-Security-Policy" content="\#(policy)">"#))
        #expect(policy.contains("default-src 'none'"))
        #expect(!policy.contains("script-src 'unsafe-inline'"))
        #expect(policy.contains("script-src 'sha256-"))

        // The hash in the policy is the hash of the script actually shipped.
        let start = try #require(html.range(of: "<script>")), end = try #require(html.range(of: "</script>"))
        let script = String(html[start.upperBound..<end.lowerBound])
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        #expect(policy.contains("'sha256-\(hash)'"))
    }
}
