import Foundation
import Synchronization
import Testing
import WilcoCore
import WilcoTranscription
@testable import WilcoBench

@Suite("Transcript normalizer")
struct TranscriptNormalizerTests {
    @Test func lowercasesAndDropsPunctuation() {
        #expect(TranscriptNormalizer.words("Standby, Lighting!") == ["standby", "lighting"])
    }

    @Test func spellsOutNumbers() {
        #expect(TranscriptNormalizer.words("cue 42") == ["cue", "forty", "two"])
        #expect(TranscriptNormalizer.words("cue forty-two") == ["cue", "forty", "two"])
        #expect(TranscriptNormalizer.words("cue 105") == ["cue", "one", "hundred", "five"])
        #expect(TranscriptNormalizer.words("0") == ["zero"])
    }

    @Test func readsCueShorthand() {
        #expect(TranscriptNormalizer.words("Q5 go") == ["cue", "five", "go"])
        #expect(TranscriptNormalizer.words("queue 5") == ["cue", "five"])
    }

    @Test func joinsStandBy() {
        #expect(TranscriptNormalizer.words("stand by sound") == ["standby", "sound"])
        #expect(TranscriptNormalizer.words("Stand-by") == ["standby"])
    }

    @Test func treatsOKAsOkay() {
        #expect(TranscriptNormalizer.words("OK, thanks") == ["okay", "thanks"])
    }
}

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        let errors = WordErrorRate.compare(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"])
        #expect(errors.errors == 0)
        #expect(errors.rate == 0)
    }

    @Test func countsEachKindOfError() {
        // "a b c d" -> "a x c d e": one substitution, one insertion.
        let errors = WordErrorRate.compare(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c", "d", "e"])
        #expect(errors == WordErrors(substitutions: 1, deletions: 0, insertions: 1, referenceWords: 4))
        #expect(errors.rate == 0.5)
    }

    @Test func missingWordsAreDeletions() {
        let errors = WordErrorRate.compare(reference: ["a", "b"], hypothesis: [])
        #expect(errors == WordErrors(substitutions: 0, deletions: 2, insertions: 0, referenceWords: 2))
    }

    @Test func errorsAddUpAcrossChannels() {
        let total = [
            WordErrors(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 4),
            WordErrors(substitutions: 0, deletions: 1, insertions: 0, referenceWords: 6),
        ].reduce(WordErrors(), +)
        #expect(total.rate == 0.2)
    }
}

@Suite("Scenario")
struct ScenarioTests {
    private let clips = [1.0, 2.0, 3.0]

    @Test func sameSeedGivesSameSchedule() {
        let a = Scenario.generate(channelCount: 4, clipDurations: clips, duration: 60, dutyCycle: 0.3, seed: 7)
        let b = Scenario.generate(channelCount: 4, clipDurations: clips, duration: 60, dutyCycle: 0.3, seed: 7)
        #expect(a == b)
        #expect(a.channels.count == 4)
        #expect(a.channels[0] != a.channels[1], "channels should not all talk at the same moments")
    }

    @Test func utterancesFitAndLeaveAPauseToCloseThem() {
        let scenario = Scenario.generate(channelCount: 8, clipDurations: clips, duration: 60, dutyCycle: 0.5, seed: 1)
        for channel in scenario.channels {
            #expect(!channel.isEmpty)
            for (previous, next) in zip(channel, channel.dropFirst()) {
                #expect(next.start - previous.end >= Scenario.minimumGap - 1e-9)
            }
            #expect(channel.last!.end <= 60 - Scenario.minimumGap)
        }
    }

    @Test func talkTimeIsNearTheDutyCycle() {
        let scenario = Scenario.generate(channelCount: 16, clipDurations: clips, duration: 600, dutyCycle: 0.3, seed: 3)
        let talk = scenario.speechSeconds / (600 * 16)
        #expect((0.24...0.36).contains(talk), "talk time \(talk)")
    }

    @Test func trackPlaysClipsAtTheirScheduledTimes() {
        let clip: [Float] = [1, 2, 3, 4]
        let track = ChannelTrack(
            utterances: [ScheduledUtterance(clip: 0, start: 2, duration: 4)],
            clips: [clip], sampleRate: 1
        )
        #expect(track.samples(from: 0, count: 8) == [0, 0, 1, 2, 3, 4, 0, 0])
        #expect(track.samples(from: 3, count: 2) == [2, 3])
    }
}

@Suite("Scorer")
struct ScorerTests {
    private let utterances = [
        ScheduledUtterance(clip: 0, start: 1, duration: 2),
        ScheduledUtterance(clip: 1, start: 5, duration: 2),
    ]
    private let texts = ["standby cue five", "cue five go"]

    private func event(_ text: String, final: Bool = true, at offset: Double, arrives: Double) -> ObservedEvent {
        ObservedEvent(text: text, isFinal: final, sessionOffset: offset, arrival: arrives)
    }

    @Test func measuresDelayFromTheEndOfEachUtterance() {
        let score = Scorer.score(utterances: utterances, texts: texts, events: [
            event("Standby cue 5", final: false, at: 1, arrives: 1.5),
            event("Standby cue 5.", at: 1, arrives: 3.5),
            event("Q5 go.", at: 5.1, arrives: 8),
        ])
        #expect(score.wordErrors.errors == 0)
        #expect(score.finalLatencies == [0.5, 1])
        #expect(score.firstWordLatencies == [0.5, 3])
        #expect(score.missed == 0)
    }

    @Test func countsUtterancesWithNoFinalLineAsMissed() {
        let score = Scorer.score(utterances: utterances, texts: texts, events: [
            event("standby cue five", at: 1, arrives: 4),
        ])
        #expect(score.missed == 1)
        #expect(score.wordErrors.deletions == 3)
    }

    @Test func scoresAMergedLineAgainstTheWholeChannel() {
        // An engine may finalise two calls as one line; the words still count.
        let score = Scorer.score(utterances: utterances, texts: texts, events: [
            event("standby cue five cue five go", at: 1, arrives: 8),
        ])
        #expect(score.wordErrors.errors == 0)
        #expect(score.missed == 1)
    }

    @Test func orderIsBySessionTimeNotArrival() {
        let score = Scorer.score(utterances: utterances, texts: texts, events: [
            event("cue five go", at: 5, arrives: 7.5),
            event("standby cue five", at: 1, arrives: 9),
        ])
        #expect(score.wordErrors.errors == 0)
    }
}

@Suite("Latency summary")
struct LatencySummaryTests {
    @Test func reportsPercentiles() throws {
        let summary = try #require(LatencySummary((1...100).map(Double.init)))
        #expect(summary.p50 == 50)
        #expect(summary.p95 == 95)
        #expect(summary.max == 100)
        #expect(LatencySummary([]) == nil)
    }
}

@Suite("Bench runner")
struct BenchRunnerTests {
    /// Writes each clip's text as a final line the moment its audio ends, so
    /// the runner's plumbing can be checked without a speech model.
    actor EchoTranscriber: ChannelTranscriber {
        let channel: BenchChannel
        let utterances: [ScheduledUtterance]
        let texts: [String]
        var pump: Task<Void, Never>?

        init(channel: BenchChannel, utterances: [ScheduledUtterance], texts: [String]) {
            self.channel = channel
            self.utterances = utterances
            self.texts = texts
        }

        func start() async {
            channel.onStatus(.listening)
            pump = Task { await self.run() }
        }

        func stop() async {
            pump?.cancel()
            await pump?.value
        }

        private func run() async {
            var heard = 0.0
            var next = 0
            while !Task.isCancelled {
                heard += Double(channel.source.ring.read(maxCount: channel.source.ring.availableToRead).count)
                    / channel.source.sampleRate()
                while next < utterances.count, utterances[next].end <= heard {
                    channel.onEvent(TranscriptionEvent(
                        channelID: channel.id, text: texts[utterances[next].clip], isFinal: true,
                        sessionOffset: utterances[next].start, confidence: nil
                    ))
                    next += 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func feedsEveryChannelInRealTimeAndScoresIt() async throws {
        let clips = [
            BenchClip(text: "standby", samples: [Float](repeating: 0.1, count: 8_000)),
            BenchClip(text: "go", samples: [Float](repeating: 0.1, count: 4_000)),
        ]
        let scenario = Scenario.generate(
            channelCount: 3, clipDurations: clips.map { $0.duration(sampleRate: 16_000) },
            duration: 4, dutyCycle: 0.3, seed: 2
        )
        let texts = clips.map(\.text)
        let engine = BenchEngine(id: "echo", summary: "test double", unavailableReason: { nil }) {
            { channel in
                EchoTranscriber(channel: channel, utterances: scenario.channels[channel.index], texts: texts)
            }
        }
        let runner = BenchRunner(clips: clips, sampleRate: 16_000)
        let result = await runner.run(engine: engine, scenario: scenario, drainTimeout: 5)

        #expect(result.failures.isEmpty)
        #expect(result.channels == 3)
        #expect(result.missed == 0)
        #expect(result.wordErrorRate == 0)
        let latency = try #require(result.finalLatency)
        // The echo answers as soon as audio arrives: only feed and pump delay.
        #expect(latency.max < 0.5, "max latency \(latency.max)")
        #expect(result.keepsUp)
    }

    @Test func reportsAnEngineThatFailsToStart() async {
        let clips = [BenchClip(text: "go", samples: [Float](repeating: 0.1, count: 4_000))]
        let scenario = Scenario.generate(channelCount: 1, clipDurations: [0.25], duration: 2, dutyCycle: 0.3, seed: 1)
        let engine = BenchEngine(id: "broken", summary: "fails", unavailableReason: { nil }) {
            { channel in FailingTranscriber(channel: channel) }
        }
        let result = await BenchRunner(clips: clips, sampleRate: 16_000)
            .run(engine: engine, scenario: scenario, drainTimeout: 1)
        #expect(result.failures == ["channel 1: no model"])
        #expect(!result.keepsUp)
    }

    actor FailingTranscriber: ChannelTranscriber {
        let channel: BenchChannel
        init(channel: BenchChannel) { self.channel = channel }
        func start() async { channel.onStatus(.failed("no model")) }
        func stop() async {}
    }
}

@Suite("Report")
struct BenchReportTests {
    @Test func roundTripsThroughJSONAndRendersATable() throws {
        let result = RunResult(
            engine: "whisper-base", channels: 8, duration: 60, dutyCycle: 0.3, speechSeconds: 140,
            utterances: 70, missed: 1, wordErrors: WordErrors(substitutions: 3, deletions: 1, insertions: 0, referenceWords: 400),
            finalLatency: LatencySummary([0.4, 0.6, 2.0]), firstWordLatency: LatencySummary([1, 2, 3]),
            startSeconds: 1.2, drainSeconds: 0.8, droppedFrames: 0,
            processCPU: 1.5, systemCPU: 0.2, peakMemoryMB: 900, failures: []
        )
        let report = BenchReport(
            date: Date(timeIntervalSince1970: 0), machine: "Test Mac", osVersion: "27.2", corpus: "say", results: [result]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(BenchReport.self, from: encoder.encode(report)) == report)

        let table = report.markdown()
        #expect(table.contains("| whisper-base | 8 |"))
        #expect(table.contains("1.0%"), "WER column: \(table)")
    }
}

@Suite("Voice selection")
struct VoiceSelectionTests {
    // macOS lists the same voice under different names over time: "Rishi"
    // one day, "Rishi (English (India))" after a voice update.
    private let listing = """
        Daniel (English (UK)) en_GB    # Hello! My name is Daniel.
        Eddy (German (Germany)) de_DE    # Hallo! Ich heiße Eddy.
        Eddy (English (UK)) en_GB    # Hello! My name is Eddy.
        Karen               en_AU    # Hello! My name is Karen.
        Samantha (Enhanced) en_US    # Hello! My name is Samantha.
        Samantha (English (US)) en_US    # Hello! My name is Samantha.
        Rishi               en_IN    # Hello! My name is Rishi.
        """

    @Test func readsNamesAndLocales() {
        let voices = ClipLibrary.parseVoices(listing)
        #expect(voices.count == 7)
        #expect(voices[0] == ClipLibrary.SystemVoice(name: "Daniel (English (UK))", locale: "en_GB"))
        #expect(voices[3].baseName == "Karen")
        #expect(voices[0].baseName == "Daniel")
    }

    @Test func matchesByBaseNameAndLocaleInPreferenceOrder() {
        let picked = ClipLibrary.pick(
            [.init(name: "Samantha", locale: "en_US"), .init(name: "Moira", locale: "en_IE"),
             .init(name: "Eddy", locale: "en_GB"), .init(name: "Karen", locale: "en_AU")],
            from: ClipLibrary.parseVoices(listing), limit: 3
        )
        // Moira isn't installed; Eddy is the English one, not the German;
        // Samantha is the standard voice, not the Enhanced download.
        #expect(picked.map(\.name) == ["Samantha (English (US))", "Eddy (English (UK))", "Karen"])
    }
}
