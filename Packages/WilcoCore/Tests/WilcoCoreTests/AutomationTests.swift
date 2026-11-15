import Foundation
import Testing
@testable import WilcoCore

@Suite("Keyword matching")
struct KeywordMatcherTests {
    @Test func matchesWholeWordsIgnoringCaseAndPunctuation() {
        #expect(KeywordMatcher.matches(["go"], in: "Lighting, GO!", mode: .containsAny) == ["go"])
        #expect(KeywordMatcher.matches(["go"], in: "Are we going?", mode: .containsAny).isEmpty)
    }

    @Test func spacingDifferencesBetweenEnginesStillMatch() {
        #expect(KeywordMatcher.matches(["standby"], in: "Stand by lighting Q5.", mode: .containsAny) == ["standby"])
        #expect(KeywordMatcher.matches(["stand by"], in: "Standby lighting Q5.", mode: .containsAny) == ["stand by"])
    }

    @Test func containsAllNeedsEveryPhrase() {
        #expect(KeywordMatcher.matches(["standby", "pyro"], in: "Standby pyro one", mode: .containsAll) == ["standby", "pyro"])
        #expect(KeywordMatcher.matches(["standby", "pyro"], in: "Standby lasers", mode: .containsAll).isEmpty)
    }

    @Test func startsWithOnlyAtTheBeginning() {
        #expect(KeywordMatcher.matches(["house"], in: "House to half", mode: .startsWith) == ["house"])
        #expect(KeywordMatcher.matches(["house"], in: "Bring the house up", mode: .startsWith).isEmpty)
    }

    @Test func regularExpressionsReturnWhatTheyMatched() {
        #expect(KeywordMatcher.matches([#"q\s?\d+"#], in: "Standby lighting Q5.", mode: .regularExpression) == ["Q5"])
        #expect(KeywordMatcher.matches(["(unclosed"], in: "anything", mode: .regularExpression).isEmpty)
    }
}

@Suite("Automation evaluation")
struct AutomationEvaluatorTests {
    private func segment(_ text: String, on channel: UUID) -> TranscriptSegment {
        TranscriptSegment(channelID: channel, text: text, timestamp: .now, sessionOffset: 0, isFinal: true)
    }

    @Test func firesEnabledRulesForTheirChannelsWithCooldown() {
        var show = ShowDocument()
        let lx = show.addChannel(), sound = show.addChannel()
        show.rules = [
            AutomationRule(name: "Any GO", phrases: ["go"], cooldown: 5),
            AutomationRule(name: "Sound only", phrases: ["go"], channelIDs: [sound.id]),
            AutomationRule(name: "Disabled", isEnabled: false, phrases: ["go"]),
        ]
        var evaluator = AutomationEvaluator()
        let start = Date()

        let first = evaluator.evaluate(segment("Lighting go", on: lx.id), in: show, at: start)
        #expect(first.map(\.rule.name) == ["Any GO"])
        #expect(first.first?.matched == ["go"])

        let tooSoon = evaluator.evaluate(segment("Go again", on: lx.id), in: show, at: start.addingTimeInterval(2))
        #expect(tooSoon.isEmpty)

        let later = evaluator.evaluate(segment("Sound go", on: sound.id), in: show, at: start.addingTimeInterval(6))
        #expect(later.map(\.rule.name) == ["Any GO", "Sound only"])
    }

    @Test func highlightsTintMatchingPhrases() {
        var show = ShowDocument()
        let channel = show.addChannel()
        show.highlights = [HighlightRule(name: "Cast", phrases: ["Omar"], tint: .purple)]

        let found = AutomationEvaluator.highlights(for: "Thanks Omar", channelID: channel.id, in: show)
        #expect(found == [SegmentHighlight(phrase: "Omar", tint: .purple)])
    }

    @Test func keywordsFollowThePieceThatSaidThem() {
        #expect(AutomationEvaluator.keywords(["go", "standby"], in: "LX 42 go") == ["go"])
    }

    @Test func keywordsInAPieceIgnoreCaseAndPartWords() {
        #expect(AutomationEvaluator.keywords(["GO", "Q5"], in: "q5 go") == ["GO", "Q5"])
        #expect(AutomationEvaluator.keywords(["go"], in: "going") == [])
    }

    @Test func evaluatesRecognisedTextWithoutASegment() {
        var show = ShowDocument()
        let channel = show.addChannel()
        show.rules = [AutomationRule(name: "GO", phrases: ["go"], cooldown: 5)]
        var evaluator = AutomationEvaluator()
        let now = Date()
        #expect(evaluator.evaluate(text: "LX go", channelID: channel.id, in: show, at: now).map(\.rule.name) == ["GO"])
        // Shares the cooldown with segment evaluation.
        #expect(evaluator.evaluate(segment("go", on: channel.id), in: show, at: now.addingTimeInterval(1)).isEmpty)
    }

    @Test func matchedKeywordsAreUniqueAcrossFirings() {
        let rule = AutomationRule(name: "x", phrases: ["go"])
        let firings = [
            AutomationEvaluator.Firing(rule: rule, matched: ["Go", "standby"]),
            AutomationEvaluator.Firing(rule: rule, matched: ["go", "LX"]),
        ]
        #expect(AutomationEvaluator.matchedKeywords(firings) == ["Go", "standby", "LX"])
    }
}

@Suite("Pending lines")
struct PendingLinesTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func keywordsFollowThePieceThatSaidThem() {
        var pending = PendingLines()
        let id = UUID()
        pending.recognized(id, text: "Standby LX 42 go", keywords: ["standby", "go"], at: start)
        #expect(pending.keywords(forPiece: "Standby LX 42", of: id, at: start) == ["standby"])
        #expect(pending.keywords(forPiece: "go", of: id, at: start) == ["go"])
        #expect(pending.count == 0, "the last piece finishes the line")
    }

    @Test func aPhraseFoundInNoPieceGoesToTheFirstPiece() {
        var pending = PendingLines()
        let id = UUID()
        // "stand by" is split across the voice change, so neither piece holds it.
        pending.recognized(id, text: "Stand by go", keywords: ["stand by", "go"], at: start)
        #expect(pending.keywords(forPiece: "Stand", of: id, at: start) == ["stand by"])
        #expect(pending.keywords(forPiece: "by go", of: id, at: start) == ["go"])
    }

    @Test func aPhraseSaidTwiceFollowsBothPieces() {
        var pending = PendingLines()
        let id = UUID()
        pending.recognized(id, text: "Go. LX go", keywords: ["go"], at: start)
        #expect(pending.keywords(forPiece: "Go.", of: id, at: start) == ["go"])
        #expect(pending.keywords(forPiece: "LX go", of: id, at: start) == ["go"])
    }

    @Test func aWholeLineKeepsAllItsKeywords() {
        var pending = PendingLines()
        let id = UUID()
        pending.recognized(id, text: "Standby go", keywords: ["standby", "go"], at: start)
        #expect(pending.keywords(forPiece: "Standby go", of: id, at: start) == ["standby", "go"])
        #expect(pending.count == 0)
    }

    @Test func anUnknownLineHasNoKeywords() {
        var pending = PendingLines()
        #expect(pending.keywords(forPiece: "go", of: UUID(), at: start) == [])
    }

    @Test func boundedByCountAndAge() {
        var pending = PendingLines(maximumLines: 3, maximumAge: 60)
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            pending.recognized(id, text: "go", keywords: ["go"], at: start.addingTimeInterval(Double(index)))
        }
        #expect(pending.count == 3)
        #expect(pending.keywords(forPiece: "go", of: ids[0], at: start.addingTimeInterval(5)) == [])
        #expect(pending.keywords(forPiece: "go", of: ids[4], at: start.addingTimeInterval(5)) == ["go"])
        // Lines whose annotation never came are dropped after a minute.
        pending.recognized(UUID(), text: "go", keywords: ["go"], at: start.addingTimeInterval(120))
        #expect(pending.count == 1)
    }
}

@Suite("Templates")
struct TemplateTests {
    private let context = TemplateContext(
        text: #"Say "hold" now"#, channel: "Stage Manager", keyword: "hold",
        date: Date(timeIntervalSince1970: 1_794_104_725), offset: 3_725.4
    )

    @Test func voicePlaceholderExpands() {
        let context = TemplateContext(text: "Go", channel: "SM", keyword: "", date: .now, offset: 0, voice: "B")
        #expect(context.expand("{channel}/{voice}") == "SM/B")
        #expect(TemplateContext(text: "Go", channel: "SM", keyword: "", date: .now, offset: 0).expand("[{voice}]") == "[]")
    }

    @Test func expandsEveryPlaceholder() {
        let tz = TimeZone(identifier: "America/Chicago")!
        #expect(context.expand("{channel}: {keyword} at {offset}", timeZone: tz) == "Stage Manager: hold at 1:02:05")
        #expect(context.expand("{time}", timeZone: tz) == "20:25:25")
    }

    @Test func escapesForJSONAndURLs() throws {
        let body = context.expand(#"{"text":"{text}"}"#, escaping: .json)
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(decoded?["text"] == #"Say "hold" now"#)

        #expect(context.expand("http://x/cue?c={channel}", escaping: .url) == "http://x/cue?c=Stage%20Manager")
    }

    @Test func webhookSendsJSONBodiesAsJSON() throws {
        let request = try #require(WebhookRequest.make(
            urlTemplate: "http://127.0.0.1:9000/cue/{keyword}", method: "POST",
            bodyTemplate: #"{"channel":"{channel}","text":"{text}"}"#, context: context
        ))
        #expect(request.url?.absoluteString == "http://127.0.0.1:9000/cue/hold")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"channel":"Stage Manager","text":"Say \"hold\" now"}"#)
    }

    @Test func webhookRejectsNonHTTPURLs() {
        #expect(WebhookRequest.make(urlTemplate: "file:///etc/passwd", method: "GET", bodyTemplate: "", context: context) == nil)
    }
}

@Suite("OSC encoding")
struct OSCEncodingTests {
    @Test func encodesAddressTypeTagsAndArgumentsWithPadding() {
        let message = OSCMessage(address: "/wilco/go", arguments: [.int(1), .float(0.5), .string("hi"), .bool(true)])
        let bytes = [UInt8](message.encoded())

        let expected: [UInt8] =
            Array("/wilco/go".utf8) + [0, 0, 0] +            // 9 + 3 = 12
            Array(",ifsT".utf8) + [0, 0, 0] +                 // 5 + 3 = 8
            [0, 0, 0, 1] +                                    // int32 1
            [0x3F, 0x00, 0x00, 0x00] +                        // float32 0.5
            Array("hi".utf8) + [0, 0]                         // "hi" + padding
        #expect(bytes == expected)
    }

    @Test func spokenTextCannotInjectAddressPatterns() {
        let context = TemplateContext(
            text: "go * /eos/cue/{1,2} [all]", channel: "Radio Pyro/2", keyword: "go?",
            date: .now, offset: 0
        )
        let message = OSCMessage(address: "/wilco/{channel}/{keyword}/{text}", arguments: [.string("a\u{0}b {text}")])
            .expanded(with: context)

        #expect(message.address == "/wilco/Radio_Pyro_2/go_/go____eos_cue__1_2___all_")
        #expect(!message.address.contains { "*?[]{},# ".contains($0) })
        #expect(message.arguments == [.string("ab go * /eos/cue/{1,2} [all]")])
    }

    @Test func addressAlwaysStartsWithASlash() {
        let context = TemplateContext(text: "", channel: "LX", keyword: "", date: .now, offset: 0)
        #expect(OSCMessage(address: "{channel}/go").expanded(with: context).address == "/LX/go")
    }

    @Test func framesForEachTransport() {
        let packet = Data([0x01, 0xC0, 0xDB, 0x02])
        #expect(OSCFraming.frame(packet, for: .udp) == packet)
        #expect([UInt8](OSCFraming.frame(packet, for: .tcpLengthPrefixed)) == [0, 0, 0, 4, 0x01, 0xC0, 0xDB, 0x02])
        #expect([UInt8](OSCFraming.frame(packet, for: .tcpSLIP)) == [0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02, 0xC0])
    }
}

@Suite("MIDI messages")
struct MIDIMessageTests {
    @Test func channelVoiceMessagesUseOneBasedChannels() {
        #expect(MIDIMessageSpec.noteOn(channel: 1, note: 60, velocity: 100).bytes == [0x90, 60, 100])
        #expect(MIDIMessageSpec.noteOff(channel: 16, note: 60).bytes == [0x8F, 60, 0])
        #expect(MIDIMessageSpec.controlChange(channel: 2, controller: 7, value: 200).bytes == [0xB1, 7, 0x7F])
        #expect(MIDIMessageSpec.programChange(channel: 10, program: 5).bytes == [0xC9, 5])
    }

    @Test func shortMessagesBecomeMIDI1ChannelVoicePackets() {
        #expect(UniversalMIDIPackets.words(for: [0x90, 0x3C, 0x64]) == [[0x2090_3C64]])
        #expect(UniversalMIDIPackets.words(for: [0xC9, 0x05]) == [[0x20C9_0500]])
    }

    @Test func sysExIsSplitIntoSixBytePackets() {
        // Six payload bytes fit one complete packet.
        #expect(UniversalMIDIPackets.words(for: [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01, 0x35, 0xF7])
                == [[0x3006_7F01, 0x0201_0135]])
        // Seven need a start packet and an end packet.
        #expect(UniversalMIDIPackets.words(for: [0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7])
                == [[0x3016_0102, 0x0304_0506], [0x3031_0700, 0x0000_0000]])
    }

    @Test func mscGoUsesLightingGeneralFormat() {
        #expect(MIDIMessageSpec.mscGo(deviceID: 1, cueNumber: "5.5", cueList: "2").bytes
                == [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01] + Array("5.5".utf8) + [0x00] + Array("2".utf8) + [0xF7])
        #expect(MIDIMessageSpec.mscGo(deviceID: 0x7F, cueNumber: "12", cueList: "").bytes
                == [0xF0, 0x7F, 0x7F, 0x02, 0x01, 0x01] + Array("12".utf8) + [0xF7])
    }
}
