import Foundation
import Testing
import WilcoCore
@testable import WilcoBench

/// A transcripts folder written by the test: one session `.jsonl` with its
/// `.clips` folder (manifest, labels and a WAV per clip).
private struct FakeShow {
    let folder: URL
    let channel = UUID()
    let otherChannel = UUID()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "realshow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes one session: `clips` with their labels, `lines` as its transcript.
    func session(
        named name: String = "Session 2026-11-20 1930-00.jsonl",
        clips: [(record: ClipRecord, label: ClipLabel?)], lines: [TranscriptSegment], dropped: Int = 0
    ) throws {
        let transcript = folder.appending(path: name)
        var data = Data()
        for line in lines { data.append(try TranscriptFile.line(for: line)) }
        try data.write(to: transcript)
        let clipsFolder = ClipsFolder.url(forTranscript: transcript)
        try ClipsFolder.save(ClipManifest(clips: clips.map(\.record), dropped: dropped), in: clipsFolder)
        try ClipsFolder.save(
            ClipLabels(voters: [ClipVoterID.parakeetUltra: "1", ClipVoterID.whisperLarge: "1"],
                       clips: clips.compactMap(\.label), finished: true),
            in: clipsFolder)
        for clip in clips {
            let samples = (0..<Int(clip.record.duration * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
            try WAV.encode(samples, sampleRate: 16_000).write(to: ClipsFolder.audioURL(for: clip.record.id, in: clipsFolder))
        }
    }

    func record(at offset: Double, duration: Double = 2, kind: ClipKind = .unclear, exchange: Int? = nil) -> ClipRecord {
        ClipRecord(channel: channel, kind: kind, sessionOffset: offset, duration: duration,
                   engine: SpeechEngine.parakeet.rawValue, exchange: exchange)
    }

    func line(_ text: String, at offset: Double) -> TranscriptSegment {
        TranscriptSegment(channelID: channel, text: text, timestamp: Date(), sessionOffset: offset, isFinal: true)
    }
}

private func agreed(_ clip: ClipRecord, _ text: String, voice: VoiceVerdict? = nil, speaker: Int? = nil) -> ClipLabel {
    ClipLabel(clip: clip.id, words: .agreed, text: text,
              candidates: [ClipVoterID.parakeetUltra: text, ClipVoterID.whisperLarge: text.lowercased()],
              voice: voice, speaker: speaker)
}

@Suite("Real-show set")
struct RealShowTests {
    @Test func loadsAnsweredClipsOnly() throws {
        let show = try FakeShow()
        let a = show.record(at: 10), b = show.record(at: 20, duration: 1.5), c = show.record(at: 30)
        try show.session(clips: [
            (a, agreed(a, "Standby lighting cue five")),
            (b, ClipLabel(clip: b.id, words: .disputed, candidates: [ClipVoterID.parakeetUltra: "go"],
                          checked: "Sound seven go")),
            (c, ClipLabel(clip: c.id, words: .disputed, candidates: [ClipVoterID.parakeetUltra: "huh"])),
        ], lines: [])

        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 48_000)
        #expect(set.clips.count == 2)
        let counts = set.counts
        let found: [Int] = [counts.sessions, counts.agreed, counts.checked, counts.disputed, counts.dropped]
        #expect(found == [1, 1, 1, 1, 0])
        #expect(set.clips.map(\.text) == ["Standby lighting cue five", "Sound seven go"])
        #expect(abs(set.clips[0].samples.count - 96_000) < 1_200)
        #expect(abs(set.clips[1].samples.count - 72_000) < 1_200)
        #expect(set.agreeingVoters[0] == [ClipVoterID.parakeetUltra, ClipVoterID.whisperLarge])
        #expect(set.agreeingVoters[1].isEmpty)
    }

    @Test func anUnreadableAnsweredClipCountsOnlyAsDropped() throws {
        let show = try FakeShow()
        let a = show.record(at: 10), b = show.record(at: 20), c = show.record(at: 30)
        try show.session(clips: [
            (a, agreed(a, "Standby lighting cue five")),
            (b, agreed(b, "Sound seven go")),
            (c, ClipLabel(clip: c.id, words: .disputed, candidates: [ClipVoterID.parakeetUltra: "go"],
                          checked: "Fly cue two go")),
        ], lines: [])
        let folder = ClipsFolder.url(forTranscript: show.folder.appending(path: "Session 2026-11-20 1930-00.jsonl"))
        try FileManager.default.removeItem(at: ClipsFolder.audioURL(for: b.id, in: folder))
        try Data("not a wav".utf8).write(to: ClipsFolder.audioURL(for: c.id, in: folder))

        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 16_000)
        let counts = set.counts
        let found: [Int] = [counts.sessions, counts.agreed, counts.checked, counts.disputed, counts.dropped]
        #expect(found == [1, 1, 0, 0, 2])
        #expect(set.clips.count == counts.agreed + counts.checked)
    }

    @Test func liveErrorsComeFromTheTranscript() throws {
        let show = try FakeShow()
        let a = show.record(at: 10), b = show.record(at: 20)
        try show.session(clips: [
            (a, agreed(a, "Standby lighting cue five")),
            (b, agreed(b, "Sound seven go")),
        ], lines: [
            show.line("Standby lighting cue nine", at: 10.2),
            show.line("Sound seven go", at: 20.1),
        ])
        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 16_000)
        #expect(set.live.errors == 1)
        #expect(set.live.referenceWords == 7)
    }

    @Test func summaryHoldsNoText() throws {
        let show = try FakeShow()
        let a = show.record(at: 10), b = show.record(at: 20)
        try show.session(clips: [
            (a, agreed(a, "Zebedee to the stage")),
            (b, agreed(b, "Thank you Zebedee")),
        ], lines: [show.line("Zebedee to the stage", at: 10)])
        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 16_000)
        #expect(!set.summary.contains("Zebedee"))
        #expect(set.summary.contains("2 clips"))

        // A run's result as the runner would make it, then the saved report.
        let result = RunResult(
            engine: "parakeet-ultra", channels: 1, duration: 60, dutyCycle: 0.3, speechSeconds: 4, utterances: 2,
            missed: 0, wordErrors: WordErrors(referenceWords: 7), startSeconds: 1, drainSeconds: 0, droppedFrames: 0,
            processCPU: 0.1, systemCPU: 0.1, peakMemoryMB: 100, failures: [],
            samples: [.init(reference: "Zebedee to the stage", hypothesis: "Zebedee to the stage")],
            nonVoterWordErrors: WordErrors(substitutions: 1, referenceWords: 3), nonVoterCalls: 1,
            voterAllWordErrors: WordErrors(substitutions: 1, referenceWords: 7), voterAllCalls: 2
        ).numbersOnly()
        var report = BenchReport(date: Date(), machine: "Mac", osVersion: "26", corpus: set.summary, results: [result])
        report.live = set.live
        report.liveClips = set.clips.count
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("Zebedee"))
        let markdown = report.markdown()
        #expect(!markdown.contains("Zebedee"))
        #expect(markdown.contains("Live on the night"))
        #expect(markdown.contains("parakeet-ultra (voter)"))
    }

    @Test func exchangesNeedAgreedVoices() throws {
        let show = try FakeShow()
        let x1 = show.record(at: 10, kind: .exchange, exchange: 1)
        let x2 = show.record(at: 13, kind: .exchange, exchange: 1)
        let x3 = show.record(at: 20, kind: .exchange, exchange: 1)
        let y1 = show.record(at: 100, kind: .exchange, exchange: 2)
        let y2 = show.record(at: 102.5, kind: .exchange, exchange: 2)
        let y3 = show.record(at: 105, kind: .exchange, exchange: 2)
        try show.session(clips: [
            (x1, agreed(x1, "Standby sound", voice: .agreed, speaker: 0)),
            (x2, agreed(x2, "Standing by", voice: .agreed, speaker: 1)),
            (x3, agreed(x3, "Sound go", voice: .agreed, speaker: 0)),
            (y1, agreed(y1, "Deck clear", voice: .agreed, speaker: 0)),
            (y2, agreed(y2, "Copy that", voice: .disputed, speaker: 1)),
            (y3, agreed(y3, "Thanks", voice: .agreed, speaker: 0)),
        ], lines: [])
        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 16_000)
        #expect(set.clips.count == 6)
        #expect(set.exchanges.count == 1)
        let exchange = try #require(set.exchanges.first)
        #expect(exchange.clips == [0, 1, 2])
        // 10 + 2 → 13 is 1 s; 13 + 2 → 20 is 5 s, capped at 3.
        #expect(exchange.gaps.count == 2)
        #expect(abs(exchange.gaps[0] - 1) < 1e-9 && abs(exchange.gaps[1] - 3) < 1e-9)
        // Same speaker on the same channel is the same voice; a disputed voice is a fresh one.
        #expect(set.clips[0].voice == set.clips[2].voice)
        #expect(set.clips[0].voice != set.clips[1].voice)
        #expect(Set([set.clips[0].voice, set.clips[1].voice, set.clips[4].voice]).count == 3)
    }

    @Test func voicesAreTheirOwnPerSessionAndChannel() throws {
        let show = try FakeShow()
        let a = show.record(at: 10)
        try show.session(named: "Session 2026-11-20 1930-00.jsonl",
                         clips: [(a, agreed(a, "One", voice: .agreed, speaker: 0))], lines: [])
        let b = show.record(at: 10)
        try show.session(named: "Session 2026-11-21 1930-00.jsonl",
                         clips: [(b, agreed(b, "Two", voice: .agreed, speaker: 0))], lines: [], dropped: 3)
        let set = try RealShowSet.load(transcripts: show.folder, sampleRate: 16_000)
        #expect(set.clips.count == 2)
        #expect(set.clips[0].voice != set.clips[1].voice)
        #expect(set.counts.sessions == 2 && set.counts.dropped == 3)
    }

    @Test func realExchangesKeepOrderAndGaps() {
        let clips = [ConversationClip(duration: 2, voice: 0), ConversationClip(duration: 2, voice: 1),
                     ConversationClip(duration: 2, voice: 0)]
        let scenario = Scenario.generateRealExchanges(
            channels: 1, duration: 60, seed: 1, exchanges: [RealExchange(clips: [0, 1, 2], gaps: [1, 5])], clips: clips)
        let placed = scenario.channels[0]
        #expect(placed.count >= 3)
        let t = placed[0].start
        #expect(placed.prefix(3).map(\.clip) == [0, 1, 2])
        #expect(abs(placed[1].start - (t + 3)) < 1e-9)
        #expect(abs(placed[2].start - (t + 8)) < 1e-9)
        #expect(Set(placed.prefix(3).map(\.exchange)).count == 1)
        #expect(placed.prefix(3).map(\.voice) == [0, 1, 0])
        for later in placed.dropFirst(3) { #expect(later.exchange != placed[0].exchange) }
        #expect(placed.last!.end <= 60 - Scenario.minimumGap)
    }

    @Test func realExchangesFillChannelsRoundRobin() {
        let clips = (0..<4).map { ConversationClip(duration: 2, voice: $0 % 2) }
        let scenario = Scenario.generateRealExchanges(
            channels: 2, duration: 30, seed: 1,
            exchanges: [RealExchange(clips: [0, 1], gaps: [0.5]), RealExchange(clips: [2, 3], gaps: [0.5])],
            clips: clips)
        #expect(scenario.channels[0].first?.clip == 0)
        #expect(scenario.channels[1].first?.clip == 2)
    }

    /// The first clip of each exchange placed on each channel, in order.
    private func exchangeStarts(_ scenario: Scenario) -> [[Int]] {
        scenario.channels.map { placed in
            var seen: [Int?] = []
            var starts: [Int] = []
            for u in placed where !seen.contains(u.exchange) {
                seen.append(u.exchange)
                starts.append(u.clip)
            }
            return starts
        }
    }

    @Test func realExchangesTwoChannelsTwoExchangesAlternate() {
        let clips = (0..<4).map { ConversationClip(duration: 2, voice: $0 % 2) }
        let scenario = Scenario.generateRealExchanges(
            channels: 2, duration: 200, seed: 1,
            exchanges: [RealExchange(clips: [0, 1], gaps: [0.5]), RealExchange(clips: [2, 3], gaps: [0.5])],
            clips: clips)
        let starts = exchangeStarts(scenario)
        for channel in starts {
            #expect(channel.count >= 2)
            for (a, b) in zip(channel, channel.dropFirst()) { #expect(a != b) }
        }
        #expect(starts[0].first == 0 && starts[1].first == 2)
        let numbers = scenario.channels.joined().map(\.exchange)
        #expect(Set(numbers).count == numbers.count / 2)
    }

    @Test func realExchangesThreeChannelsTwoExchangesUseBoth() {
        let clips = (0..<4).map { ConversationClip(duration: 2, voice: $0 % 2) }
        let scenario = Scenario.generateRealExchanges(
            channels: 3, duration: 200, seed: 1,
            exchanges: [RealExchange(clips: [0, 1], gaps: [0.5]), RealExchange(clips: [2, 3], gaps: [0.5])],
            clips: clips)
        let starts = exchangeStarts(scenario)
        #expect(starts.map(\.first) == [0, 2, 0])
        for channel in starts {
            #expect(channel.count >= 2)
            for (a, b) in zip(channel, channel.dropFirst()) { #expect(a != b) }
        }
    }

    @Test func scorerCountsOnlyTheChosenClips() {
        let utterances = [ScheduledUtterance(clip: 0, start: 0, duration: 2),
                          ScheduledUtterance(clip: 1, start: 5, duration: 2)]
        let texts = ["standby lighting", "sound go"]
        let events = [ObservedEvent(text: "standby lightning", isFinal: true, sessionOffset: 0.1, arrival: 2.5),
                      ObservedEvent(text: "sound go", isFinal: true, sessionOffset: 5.1, arrival: 7.5)]
        let all = Scorer.wordErrors(utterances: utterances, texts: texts, events: events, clips: [0, 1])
        #expect(all.errors == 1 && all.referenceWords == 4)
        let second = Scorer.wordErrors(utterances: utterances, texts: texts, events: events, clips: [1])
        #expect(second.errors == 0 && second.referenceWords == 2)
    }

    private func voterResult(fair: WordErrors, fairCalls: Int, all: WordErrors, allCalls: Int) -> RunResult {
        RunResult(
            engine: "parakeet-ultra", channels: 1, duration: 60, dutyCycle: 0.3, speechSeconds: 4, utterances: allCalls,
            missed: 0, wordErrors: all, startSeconds: 1, drainSeconds: 0, droppedFrames: 0,
            processCPU: 0.1, systemCPU: 0.1, peakMemoryMB: 100, failures: [],
            nonVoterWordErrors: fair, nonVoterCalls: fairCalls, voterAllWordErrors: all, voterAllCalls: allCalls
        )
    }

    @Test func voterLineComparesLikeWithLike() {
        let r = voterResult(fair: WordErrors(substitutions: 1, referenceWords: 10), fairCalls: 4,
                            all: WordErrors(substitutions: 1, referenceWords: 20), allCalls: 9)
        let line = BenchReport.voterLine(r)
        #expect(line.contains("10.0%") && line.contains("4 calls"))
        #expect(line.contains("5.0%") && line.contains("9 calls"))
        #expect(line.contains("per call"))
        let report = BenchReport(date: Date(), machine: "Mac", osVersion: "26", corpus: "real show", results: [r])
        #expect(report.markdown().contains(line))
    }

    @Test func voterLineWithNoFairCallsShowsNoRate() {
        let r = voterResult(fair: WordErrors(), fairCalls: 0,
                            all: WordErrors(substitutions: 1, referenceWords: 20), allCalls: 9)
        let line = BenchReport.voterLine(r)
        #expect(!line.contains("0 calls"))
        #expect(!line.contains("0.0%"))
        #expect(line.contains("–"))
        #expect(line.contains("5.0%") && line.contains("9 calls"))
    }

    @Test func voterEnginesMapToTheirVoter() {
        #expect(RealShowSet.voter(forEngine: "parakeet-ultra") == ClipVoterID.parakeetUltra)
        #expect(RealShowSet.voter(forEngine: "apple-longform-voices") == ClipVoterID.appleLongForm)
        #expect(RealShowSet.voter(forEngine: "whisper-large") == ClipVoterID.whisperLarge)
        #expect(RealShowSet.voter(forEngine: "parakeet-v3") == nil)
    }
}
