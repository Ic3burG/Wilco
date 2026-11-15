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

@Suite("Conversation scenario")
struct ConversationScenarioTests {
    /// Three calls in each of four voices, 1.5–2.5 s long.
    private let clips = (0..<12).map { ConversationClip(duration: 1.5 + Double($0 % 3) * 0.5, voice: $0 / 3) }

    @Test func sameSeedGivesSameConversations() {
        let a = Scenario.generateConversations(channels: 8, duration: 120, seed: 3, clips: clips)
        let b = Scenario.generateConversations(channels: 8, duration: 120, seed: 3, clips: clips)
        #expect(a == b)
        #expect(a.channels.count == 8)
        #expect(a.channels[0] != a.channels[1])
    }

    @Test func exchangesHaveTurnsThatMergeAndVoicesThatReturn() {
        let scenario = Scenario.generateConversations(channels: 8, duration: 120, seed: 3, clips: clips)
        var backToBack = 0, returning = 0
        for channel in scenario.channels {
            #expect(!channel.isEmpty)
            #expect(channel.last!.end <= 120)
            let exchanges = Dictionary(grouping: channel) { $0.exchange! }
            for (_, turns) in exchanges {
                #expect((2...5).contains(turns.count), "\(turns.count) turns")
                #expect((2...4).contains(Set(turns.map(\.voice)).count))
                var seen: Set<Int> = []
                for (previous, next) in zip(turns, turns.dropFirst()) {
                    let gap = next.start - previous.end
                    #expect(gap >= 0.1 - 1e-9 && gap <= 0.8 + 1e-9, "gap \(gap)")
                    #expect(next.voice != previous.voice, "a turn is a different voice")
                    if gap < 0.5 { backToBack += 1 }
                }
                for turn in turns {
                    if seen.contains(turn.voice!) { returning += 1 }
                    seen.insert(turn.voice!)
                    #expect(clips[turn.clip].voice == turn.voice)
                }
            }
            for (previous, next) in zip(channel, channel.dropFirst()) where previous.exchange != next.exchange {
                let quiet = next.start - previous.end
                #expect(quiet >= 25 - 1e-9 && quiet <= 40 + 1e-9, "quiet \(quiet)")
            }
        }
        #expect(backToBack > 0)
        #expect(returning > 0)
    }
}

@Suite("Voice scoring")
struct VoiceScoringTests {
    /// One exchange: voices 0, 1, 0, 1, 0, each turn on its own line.
    private let turns = [0.0, 3, 6, 9, 12].enumerated().map { index, start in
        ScheduledUtterance(clip: index, start: start, duration: 2, voice: index % 2, exchange: 1)
    }

    private func piece(_ voice: String?, at offset: Double, line: UUID = UUID()) -> ObservedEvent {
        ObservedEvent(text: "x", isFinal: true, sessionOffset: offset, arrival: offset + 3, lineID: line,
                      stage: .annotated(voice: voice, exchange: 1))
    }

    @Test func countsMissedAndFalseChangesAndReturningLetters() {
        let score = Scorer.scoreVoices(utterances: turns, events: [
            piece("A", at: 0), piece("B", at: 3), piece("A", at: 6),
            // The change at 9 s is missed, and one is found inside that turn.
            piece("A", at: 9), piece("B", at: 10.5),
            piece("A", at: 12),
        ])
        #expect(score.changes == 4)
        #expect(score.missedChanges == 1)
        #expect(score.falseChanges == 1)
        #expect(score.returningTurns == 3)
        #expect(score.correctLetters == 2)
        #expect(score.letterAccuracy == 2.0 / 3.0)
    }

    @Test func aMergedTurnIsAMissedChange() {
        let merged = [
            ScheduledUtterance(clip: 0, start: 0, duration: 2, voice: 0, exchange: 1),
            ScheduledUtterance(clip: 1, start: 2.3, duration: 2, voice: 1, exchange: 1),
        ]
        let score = Scorer.scoreVoices(utterances: merged, events: [piece("A", at: 0)])
        #expect(score.changes == 1)
        #expect(score.missedChanges == 1)
        #expect(score.falseChanges == 0)
    }

    @Test func aNewExchangeIsNotAChange() {
        let calls = [
            ScheduledUtterance(clip: 0, start: 0, duration: 2, voice: 0, exchange: 1),
            ScheduledUtterance(clip: 1, start: 30, duration: 2, voice: 1, exchange: 2),
        ]
        let events = [
            piece("A", at: 0),
            ObservedEvent(text: "x", isFinal: true, sessionOffset: 30, arrival: 33,
                          stage: .annotated(voice: "A", exchange: 2)),
        ]
        let score = Scorer.scoreVoices(utterances: calls, events: events)
        #expect(score.changes == 0)
        #expect(score.missedChanges == 0)
        #expect(score.falseChanges == 0)
    }

    @Test func countsLinesWithoutLettersAndAnnotationsThatNeverCame() {
        let annotated = UUID(), lost = UUID()
        let score = Scorer.scoreVoices(utterances: Array(turns.prefix(2)), events: [
            ObservedEvent(text: "x", isFinal: true, sessionOffset: 0, arrival: 2.5, lineID: annotated, stage: .recognized),
            piece(nil, at: 0, line: annotated),
            ObservedEvent(text: "x", isFinal: true, sessionOffset: 3, arrival: 5.5, lineID: lost, stage: .recognized),
        ])
        #expect(score.lines == 1)
        #expect(score.unlettered == 1)
        #expect(score.missingAnnotations == 1)
    }

    @Test func scoresAddUpAcrossChannels() {
        let a = VoiceScore(changes: 4, missedChanges: 1, falseChanges: 1, returningTurns: 3, correctLetters: 2,
                           lines: 6, unlettered: 0, missingAnnotations: 0)
        let total = a + a
        #expect(total.changes == 8)
        #expect(total.letterAccuracy == 2.0 / 3.0)
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

    @Test func completeLinesShowWhenTheyArrive() {
        let score = Scorer.score(utterances: utterances, texts: texts, events: [
            event("Standby cue 5.", at: 1, arrives: 3.5),
            event("Q5 go.", at: 5.1, arrives: 8),
        ])
        #expect(score.displayLatencies == score.finalLatencies)
    }

    @Test func twoStageLinesCountOnceWithRulesAndDisplayDelays() {
        // Rules see the recognised line; the screen shows its annotated
        // pieces later. Words are counted once, from the recognised line.
        let first = UUID(), second = UUID()
        let events = [
            ObservedEvent(text: "Standby cue 5.", isFinal: true, sessionOffset: 1, arrival: 3.5, lineID: first,
                          stage: .recognized),
            ObservedEvent(text: "Standby", isFinal: true, sessionOffset: 1, arrival: 3.75, lineID: first,
                          stage: .annotated(voice: "A", exchange: 1)),
            ObservedEvent(text: "cue 5.", isFinal: true, sessionOffset: 1.8, arrival: 4, lineID: first,
                          stage: .annotated(voice: "B", exchange: 1)),
            ObservedEvent(text: "Q5 go.", isFinal: true, sessionOffset: 5.1, arrival: 8, lineID: second,
                          stage: .recognized),
        ]
        let score = Scorer.score(utterances: utterances, texts: texts, events: events, watchedUntil: 20)
        #expect(score.wordErrors.errors == 0)
        #expect(score.hypothesis == "Standby cue 5. Q5 go.")
        #expect(score.finalLatencies == [0.5, 1])
        // The second call's annotation never came: it counts as arriving when
        // the run stopped watching, a lower bound on its delay.
        #expect(score.displayLatencies == [1, 13])
        #expect(score.missingAnnotations == 1)
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

    @Test func backToBackCallsInOneLineAreMergedNotMissed() {
        // Two turns 0.25 s apart come out as one line: it answers both, and its
        // delay runs from the end of the second.
        let turns = [
            ScheduledUtterance(clip: 0, start: 1, duration: 2),
            ScheduledUtterance(clip: 1, start: 3.25, duration: 2),
        ]
        let score = Scorer.score(utterances: turns, texts: texts, events: [
            event("standby cue five cue five go", at: 1, arrives: 5.75),
        ])
        #expect(score.missed == 0)
        #expect(score.merged == 1)
        #expect(score.finalLatencies == [0.5])
        #expect(score.displayLatencies == [0.5])
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

@Suite("Keeping up with voices")
struct VoiceKeepUpTests {
    private func result(display: [Double], backlog: Double, voices: Bool) -> RunResult {
        var r = RunResult(
            engine: voices ? "parakeet-v3-voices" : "parakeet-v3", channels: 32, duration: 60, dutyCycle: 0.2,
            speechSeconds: 100, utterances: 100, missed: 0, wordErrors: WordErrors(),
            finalLatency: LatencySummary([0.5, 0.7]), displayLatency: LatencySummary(display),
            firstWordLatency: nil, startSeconds: 1, drainSeconds: 0.5, droppedFrames: 0,
            processCPU: 1, systemCPU: 0.2, peakMemoryMB: 500, failures: []
        )
        r.displayBacklog = backlog
        if voices {
            r.voices = VoiceScore(changes: 10, missedChanges: 2, falseChanges: 1, returningTurns: 4,
                                  correctLetters: 3, lines: 20, unlettered: 1, missingAnnotations: 0)
        }
        return r
    }

    @Test func cuesKeepUpOnFinalDelayAlone() {
        let r = result(display: [5, 6], backlog: 6, voices: false)
        #expect(r.cuesKeepUp)
        #expect(r.displayKeepsUp == nil)
        #expect(r.keepsUp)
    }

    @Test func voicesMustAlsoKeepTheDisplayWithinThreeSeconds() {
        #expect(result(display: [0.8, 1.2], backlog: 1, voices: true).keepsUp)
        let slow = result(display: [0.8, 4], backlog: 1, voices: true)
        #expect(slow.cuesKeepUp)
        #expect(slow.displayKeepsUp == false)
        #expect(!slow.keepsUp)
        #expect(!result(display: [0.8, 1.2], backlog: 3.5, voices: true).keepsUp)
    }

    @Test func reportShowsTheVoiceTable() {
        let report = BenchReport(date: Date(timeIntervalSince1970: 0), machine: "Test Mac", osVersion: "27.2",
                                 corpus: "say", results: [result(display: [0.8, 1.2], backlog: 1, voices: true)])
        let text = report.markdown()
        #expect(text.contains("## Voice changes"))
        #expect(text.contains("| parakeet-v3-voices | 32 | 2/10 | 1 | 75% |"), "\(text)")
    }
}

@Suite("Corpus speakers")
struct CorpusSpeakerTests {
    @Test func readsASpeakerMarkPerLine() throws {
        let marked = try ClipLibrary.transcript("A: Standby lighting cue five.\nA: Lighting five, go.\n")
        #expect(marked.text == "Standby lighting cue five. Lighting five, go.")
        #expect(marked.speaker == "A")
        let plain = try ClipLibrary.transcript("Standby lighting cue five.")
        #expect(plain.speaker == nil)
        #expect(plain.text == "Standby lighting cue five.")
    }

    @Test func refusesTwoSpeakersInOneRecording() {
        #expect(throws: BenchError.self) { try ClipLibrary.transcript("A: Standby.\nB: Standing by.") }
    }

    @Test func speakersBecomeVoiceNumbers() {
        // Unmarked recordings share one voice of their own.
        #expect(ClipLibrary.voiceNumbers(for: ["B", nil, "A", "B"]) == [2, 0, 1, 2])
    }
}

@Suite("Clip vocabulary")
struct ClipVocabularyTests {
    @Test func everyTermIsSpokenInAPhrase() {
        let spoken = ClipLibrary.phrases.joined(separator: " ").lowercased()
        for term in ClipLibrary.vocabulary {
            #expect(spoken.contains(term.lowercased()), "\(term)")
        }
    }

    @Test func vocabularyEngineIsListed() {
        #expect(BenchEngine.named("parakeet-v3-vocab") != nil)
    }

    @Test func voiceEnginesAreListed() {
        for id in ["parakeet-v3-voices", "apple-longform-voices", "whisper-base-voices"] {
            #expect(BenchEngine.named(id)?.detectsVoiceChanges == true, "\(id)")
        }
        #expect(BenchEngine.named("parakeet-v3")?.detectsVoiceChanges == false)
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
