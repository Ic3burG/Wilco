import Foundation
import Testing
import WilcoCore
import WilcoTranscription
@testable import WilcoBench

@Suite("Long talks")
struct LongTalkTests {
    @Test func echoesLandAtTheirDelays() {
        var impulse = [Float](repeating: 0, count: 100)
        impulse[0] = 1
        let out = RoomSound.echoed(impulse, sampleRate: 1_000)
        #expect(out.count == 100 + 210)
        #expect(out[0] == 1 && out[30] == 0.5 && out[70] == 0.35 && out[130] == 0.25 && out[210] == 0.15)
        #expect(out[31] == 0)
    }

    @Test func hissIsTheSameForTheSameFrame() {
        let a = (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) }
        #expect(a == (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) })
        #expect(a != (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 8) })
        let loudest = a.map(abs).max() ?? 0
        #expect(loudest <= 0.002)
        #expect(Set(a).count > 900)
    }

    @Test func passagesAreLongAndPlainWords() {
        #expect(ClipLibrary.passages.count >= 6)
        for passage in ClipLibrary.passages {
            let words = TranscriptNormalizer.words(passage)
            #expect((30...75).contains(words.count), "\(words.count) words")  // about 10–25 s
            let hasDigits = passage.contains(where: \.isNumber)
            #expect(!hasDigits)
        }
    }

    @Test func longTalksAreSeededSpacedAndWhole() throws {
        let durations = [12.0, 18.0, 24.0]
        let a = Scenario.generateLongTalks(channels: 8, clipDurations: durations, duration: 120, seed: 3)
        #expect(a == Scenario.generateLongTalks(channels: 8, clipDurations: durations, duration: 120, seed: 3))
        #expect(a != Scenario.generateLongTalks(channels: 8, clipDurations: durations, duration: 120, seed: 4))
        #expect(a.longTalk && a.hiss == 0.002)
        var quiet = 0, total = 0
        for channel in a.channels {
            #expect(!channel.isEmpty)
            for (talk, next) in zip(channel, channel.dropFirst()) {
                let gap = next.start - talk.end
                #expect((3.0...8.0).contains(gap), "gap \(gap)")
            }
            let lastEnd = try #require(channel.last).end
            #expect(lastEnd <= 120 - Scenario.minimumGap)
            let steady = Set(channel.filter { $0.quietFrom == nil }.compactMap { $0.gain })
            #expect(steady.count <= 1)  // one level per channel
            for talk in channel {
                total += 1
                #expect(talk.duration == durations[talk.clip])
                if let from = talk.quietFrom {
                    quiet += 1
                    #expect(talk.gain == 0.3 && from == talk.duration / 2)
                } else {
                    let gain = try #require(talk.gain)
                    #expect((0.1...0.3).contains(gain))
                }
            }
        }
        #expect(quiet > 0 && quiet < total / 2)
        let levels = Set(a.channels.compactMap { $0.first { $0.quietFrom == nil }?.gain })
        #expect(levels.count > 1)  // channels differ
    }

    @Test func trackAppliesGainTheQuietHalfAndHiss() {
        let clip = [Float](repeating: 1, count: 1_000)
        let talk = ScheduledUtterance(clip: 0, start: 1, duration: 1, gain: 0.3, quietFrom: 0.5)
        let track = ChannelTrack(utterances: [talk], clips: [clip], sampleRate: 1_000, hiss: 0.002, hissSeed: 5)
        let all = track.samples(from: 0, count: 3_000)
        #expect(abs(all[1_100] - 0.3) <= 0.002 && abs(all[1_700] - 0.06) <= 0.002)
        #expect(all[500] != 0 && abs(all[500]) <= 0.002)  // hiss between talks
        // The same audio however it's chunked.
        let chunked = stride(from: 0, to: 3_000, by: 137).flatMap {
            track.samples(from: $0, count: min(137, 3_000 - $0))
        }
        #expect(chunked == all)
        let other = ChannelTrack(utterances: [talk], clips: [clip], sampleRate: 1_000, hiss: 0.002, hissSeed: 6)
        #expect(other.samples(from: 0, count: 3_000) != all)
    }

    @Test func defaultTrackIsUnchanged() {
        let clip = [Float](repeating: 0.5, count: 100)
        let track = ChannelTrack(
            utterances: [.init(clip: 0, start: 0, duration: 0.1)], clips: [clip], sampleRate: 1_000
        )
        #expect(track.samples(from: 0, count: 200) == clip + [Float](repeating: 0, count: 100))
    }

    static func result(deletions: Int, longTalk: Bool?) -> RunResult {
        RunResult(
            engine: "parakeet-v3", channels: 8, duration: 120, dutyCycle: 0.7, speechSeconds: 600,
            utterances: 40, missed: 0, wordErrors: WordErrors(deletions: deletions, referenceWords: 100),
            finalLatency: LatencySummary([0.5, 0.7]), firstWordLatency: nil,
            startSeconds: 1, drainSeconds: 0.5, droppedFrames: 0,
            processCPU: 1, systemCPU: 0.2, peakMemoryMB: 500, failures: [], longTalk: longTalk
        )
    }

    @Test func wordsLostFailsOnlyLongTalkRuns() {
        #expect(Self.result(deletions: 20, longTalk: nil).wordsLost == 0.2)
        #expect(Self.result(deletions: 20, longTalk: nil).keepsUp)
        #expect(!Self.result(deletions: 20, longTalk: true).keepsUp)
        #expect(Self.result(deletions: 10, longTalk: true).keepsUp)
        #expect(Self.result(deletions: 11, longTalk: true).keepsUp == false)
        var empty = Self.result(deletions: 0, longTalk: true)
        empty.wordErrors = WordErrors()
        #expect(empty.wordsLost == 0)
    }

    @Test func olderReportsStillDecode() throws {
        let data = try JSONEncoder().encode(Self.result(deletions: 20, longTalk: true))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.removeValue(forKey: "longTalk") != nil)
        let old = try JSONDecoder().decode(RunResult.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.longTalk == nil)
        #expect(old.keepsUp)
    }

    @Test func longTalkRowHasWordsLost() {
        let plain = BenchReport.tableRow(Self.result(deletions: 20, longTalk: nil))
        let long = BenchReport.tableRow(Self.result(deletions: 20, longTalk: true))
        func cells(_ row: String) -> Int { row.split(separator: "|").count }
        #expect(cells(long) == cells(plain) + 1)
        #expect(long.contains("| 20.0% | 20.0% |"))  // WER, then words lost
        #expect(BenchReport.tableHeader(longTalk: true).contains("| WER | Words lost |"))
        #expect(BenchReport.tableHeader(longTalk: false) == BenchReport.tableHeader)
        for line in BenchReport.tableHeader(longTalk: true).split(separator: "\n") {
            #expect(cells(String(line)) == cells(long))
        }
        let report = BenchReport(
            date: Date(timeIntervalSince1970: 0), machine: "Test Mac", osVersion: "27.2", corpus: "say",
            results: [Self.result(deletions: 20, longTalk: true)]
        )
        #expect(report.markdown().contains("| WER | Words lost |"))
        #expect(report.markdown().contains("Words lost:"))
    }

    /// Writes the first `share` of each talk's words as one final line when
    /// the talk ends: an engine whose segmenter stopped listening partway.
    actor PartialTranscriber: ChannelTranscriber {
        let channel: BenchChannel
        let utterances: [ScheduledUtterance]
        let texts: [String]
        let share: Double
        var pump: Task<Void, Never>?

        init(channel: BenchChannel, utterances: [ScheduledUtterance], texts: [String], share: Double) {
            self.channel = channel
            self.utterances = utterances
            self.texts = texts
            self.share = share
        }

        func start() async {
            channel.onStatus(.listening)
            pump = Task { await self.run() }
        }

        func stop() async {
            pump?.cancel()
            await pump?.value
        }

        func updateVoiceSettings(_ settings: VoiceChangeSettings) async {}

        private func run() async {
            var heard = 0.0
            var next = 0
            while !Task.isCancelled {
                heard += Double(channel.source.ring.read(maxCount: channel.source.ring.availableToRead).count)
                    / channel.source.sampleRate()
                while next < utterances.count, utterances[next].end <= heard {
                    let words = texts[utterances[next].clip].split(separator: " ")
                    let kept = words.prefix(Int(Double(words.count) * share)).joined(separator: " ")
                    channel.onEvent(TranscriptionEvent(
                        channelID: channel.id, text: kept, isFinal: true,
                        sessionOffset: utterances[next].start, confidence: nil
                    ))
                    next += 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0.5, 1.0])
    func anEngineThatDropsTheSecondHalfDoesNotKeepUp(share: Double) async {
        let clips = [
            BenchClip(text: "one two three four five six seven eight", samples: [Float](repeating: 0.1, count: 48_000)),
            BenchClip(text: "red blue green pink grey black white gold", samples: [Float](repeating: 0.1, count: 48_000)),
        ]
        let scenario = Scenario.generateLongTalks(channels: 2, clipDurations: [3, 3], duration: 20, seed: 1)
        let texts = clips.map(\.text)
        let engine = BenchEngine(id: "partial", summary: "test double", unavailableReason: { nil }) {
            { channel in
                PartialTranscriber(
                    channel: channel, utterances: scenario.channels[channel.index], texts: texts, share: share
                )
            }
        }
        let result = await BenchRunner(clips: clips, sampleRate: 16_000)
            .run(engine: engine, scenario: scenario, drainTimeout: 5)
        #expect(result.failures.isEmpty)
        #expect(result.longTalk == true)
        #expect(result.utterances > 0 && result.missed == 0)
        if share < 1 {
            #expect(result.wordsLost > 0.4, "words lost \(result.wordsLost)")
            #expect(!result.keepsUp)
        } else {
            #expect(result.wordsLost == 0)
            #expect(result.keepsUp)
        }
    }

    /// Writes a talk as two lines: the first half midway through it, the
    /// rest `lag` seconds after it ends, like an engine that cuts a long
    /// talk in two and is slow with the second part.
    actor TwoLineTranscriber: ChannelTranscriber {
        let channel: BenchChannel
        let talk: ScheduledUtterance
        let words: [Substring]
        let lag: Double
        var pump: Task<Void, Never>?

        init(channel: BenchChannel, talk: ScheduledUtterance, text: String, lag: Double) {
            self.channel = channel
            self.talk = talk
            words = text.split(separator: " ")
            self.lag = lag
        }

        func start() async {
            channel.onStatus(.listening)
            pump = Task { await self.run() }
        }

        func stop() async {
            pump?.cancel()
            await pump?.value
        }

        func updateVoiceSettings(_ settings: VoiceChangeSettings) async {}

        private func run() async {
            var heard = 0.0
            var sent = 0
            let middle = talk.start + talk.duration / 2
            while !Task.isCancelled {
                heard += Double(channel.source.ring.read(maxCount: channel.source.ring.availableToRead).count)
                    / channel.source.sampleRate()
                if sent == 0, heard >= middle {
                    send(words.prefix(words.count / 2), at: talk.start)
                    sent = 1
                } else if sent == 1, heard >= talk.end + lag {
                    send(words.suffix(words.count - words.count / 2), at: middle)
                    sent = 2
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        private func send(_ words: some Sequence<Substring>, at offset: Double) {
            channel.onEvent(TranscriptionEvent(
                channelID: channel.id, text: words.joined(separator: " "), isFinal: true,
                sessionOffset: offset, confidence: nil
            ))
        }
    }

    @Test(.timeLimit(.minutes(1))) func aLongTalkRunWaitsForATalksLastLine() async throws {
        let text = "one two three four five six seven eight"
        let clips = [BenchClip(text: text, samples: [Float](repeating: 0.1, count: 48_000))]
        let talk = ScheduledUtterance(clip: 0, start: 1, duration: 3, gain: 0.2)
        let scenario = Scenario(duration: 5.5, dutyCycle: 0.5, channels: [[talk]], longTalk: true, hiss: 0.002)
        let engine = BenchEngine(id: "two-line", summary: "test double", unavailableReason: { nil }) {
            { channel in TwoLineTranscriber(channel: channel, talk: talk, text: text, lag: 2) }
        }
        let result = await BenchRunner(clips: clips, sampleRate: 16_000)
            .run(engine: engine, scenario: scenario, drainTimeout: 10)
        // The second line comes at 6 s, after the audio stops at 5.5 s.
        #expect(result.wordsLost == 0, "words lost \(result.wordsLost)")
        #expect(result.drainSeconds > 0.3, "backlog \(result.drainSeconds)")
        let latency = try #require(result.finalLatency)
        #expect(latency.max > 1.8, "final delay \(latency.max)")
    }
}
