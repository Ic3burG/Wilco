import Foundation
import Synchronization
import WilcoCore
import WilcoTranscription

/// One recorded call and what was said in it.
public struct BenchClip: Sendable {
    public var text: String
    /// Mono, at the runner's sample rate.
    public var samples: [Float]
    /// Who says it: a `say` voice, or a corpus speaker mark, numbered from 0.
    public var voice: Int

    public init(text: String, samples: [Float], voice: Int = 0) {
        self.text = text
        self.samples = samples
        self.voice = voice
    }

    public func duration(sampleRate: Double) -> Double { Double(samples.count) / sampleRate }

    public func conversationClip(sampleRate: Double) -> ConversationClip {
        ConversationClip(duration: duration(sampleRate: sampleRate), voice: voice)
    }
}

/// Plays a scenario into many channels at once, in real time, through the
/// same ring buffers the app's capture fills, and scores what comes back.
public struct BenchRunner: Sendable {
    public var clips: [BenchClip]
    /// The rate the "device" delivers. 48 kHz, like a Dante or MADI interface.
    public var sampleRate: Double
    /// Biased into every channel, as the app biases rule phrases.
    public var vocabulary: [String] = []
    /// Used by engines that detect voice changes.
    public var voiceChanges: VoiceChangeSettings = .standard
    /// Runs the per-minute meter and sound classifier in every channel, as a
    /// live session does, writing to a temporary file that is deleted after
    /// the run. A minute closes by wall clock and clips come only from minutes
    /// with at least 3 s of sound, so runs shorter than a minute exercise only
    /// the meter's per-block work, not the classifier.
    public var diagnostics = false
    /// Real-show runs: per clip, the voters whose text matched the answer.
    /// Engines that are voters are also scored on the clips they didn't agree on.
    public var agreeingVoters: [Set<String>]?
    /// False keeps words out of the result (no samples), for real-show runs.
    public var keepsTexts = true

    public init(clips: [BenchClip], sampleRate: Double = 48_000) {
        self.clips = clips
        self.sampleRate = sampleRate
    }

    /// How often the feeder writes, standing in for the device's IO cycle.
    private static let feedInterval = Duration.milliseconds(20)
    /// A run ends once lines stop arriving for this long after the audio.
    private static let quietPeriod = 3.0

    public func run(engine: BenchEngine, scenario: Scenario, drainTimeout: Double = 30) async -> RunResult {
        let count = scenario.channels.count
        let recorder = Recorder(channelCount: count)
        // The app's capture keeps 10 s per channel.
        let rings = (0..<count).map { _ in AudioRingBuffer(capacity: Int(sampleRate * 10)) }
        let rate = sampleRate
        let factory = engine.makeFactory()
        let classifier = diagnostics ? SoundClassifierQueue() : nil
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appending(path: "wilco-bench-\(UUID().uuidString).diagnostics")
        let diagnosticsRecorder = diagnostics
            ? DiagnosticsRecorder(
                writer: DiagnosticsWriter(url: diagnosticsURL), sessionStart: Date(), classifier: classifier
            )
            : nil
        let tap = diagnosticsRecorder?.tap
        let transcribers = (0..<count).map { index in
            factory(BenchChannel(
                index: index, id: UUID(),
                source: AudioSource(ring: rings[index], sampleRate: { rate }, diagnostics: tap),
                vocabulary: vocabulary,
                voiceChanges: voiceChanges,
                onEvent: { recorder.record($0, channel: index) },
                onStatus: { recorder.status($0, channel: index) }
            ))
        }

        var meter = ResourceMeter()
        let clock = ContinuousClock()
        let startBegan = clock.now
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers { group.addTask { await transcriber.start() } }
        }
        let startSeconds = seconds(clock.now - startBegan)

        var drainSeconds = 0.0
        let origin = clock.now
        if recorder.failures.isEmpty {
            let samples = clips.map(\.samples)
            let tracks = scenario.channels.enumerated().map { index, utterances in
                ChannelTrack(
                    utterances: utterances, clips: samples, sampleRate: sampleRate,
                    hiss: scenario.hiss, hissSeed: UInt64(index)
                )
            }
            recorder.begin(at: origin)
            var written = 0
            func feed(until elapsed: Double) {
                let target = Int(elapsed * sampleRate)
                guard target > written else { return }
                for (ring, track) in zip(rings, tracks) {
                    _ = ring.write(track.samples(from: written, count: target - written))
                }
                written = target
            }

            var elapsed = 0.0
            while elapsed < scenario.duration {
                feed(until: elapsed)
                meter.sample()
                try? await Task.sleep(for: Self.feedInterval)
                elapsed = seconds(clock.now - origin)
            }
            // Keep sending silence, as a live input does, until every call has
            // a line (and every line its voice) or the engine goes quiet.
            while elapsed < scenario.duration + drainTimeout {
                feed(until: elapsed)
                meter.sample()
                // A long talk can come back as several lines, so one line
                // doesn't mean it's answered: wait for the quiet period.
                if !scenario.longTalk, allAnswered(scenario, recorder) { break }
                if elapsed - max(scenario.duration, recorder.lastArrival ?? 0) > Self.quietPeriod { break }
                try? await Task.sleep(for: Self.feedInterval)
                elapsed = seconds(clock.now - origin)
            }
            // Backlog for cues counts rule lines only; voice analysis has its own.
            drainSeconds = max(0, (recorder.lastRuleArrival ?? 0) - scenario.duration)
        }

        // Stopping annotates lines still waiting for their voice; those
        // arrivals count towards the display delay and backlog.
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers { group.addTask { await transcriber.stop() } }
        }
        let watchedUntil = seconds(clock.now - origin)
        meter.sample()
        let usage = meter.finish()
        // Finishing waits for classifications still running, which is not
        // part of what the run is measuring.
        await diagnosticsRecorder?.finish()
        let droppedClips = await classifier?.droppedClips
        // Read the file back, so "no clips dropped" can be told from "no clips".
        var diagnosticsRows: Int?
        var classifiedRows: Int?
        if diagnostics {
            let rows = (try? Data(contentsOf: diagnosticsURL)).map(DiagnosticsFile.rows(in:)) ?? []
            diagnosticsRows = rows.count
            classifiedRows = rows.filter { $0.classified != nil }.count
            try? FileManager.default.removeItem(at: diagnosticsURL)
        }

        let texts = clips.map(\.text)
        let scores = scenario.channels.enumerated().map { index, utterances in
            Scorer.score(
                utterances: utterances, texts: texts, events: recorder.events(channel: index), watchedUntil: watchedUntil
            )
        }
        let voices = engine.detectsVoiceChanges
            ? scenario.channels.enumerated()
                .map { Scorer.scoreVoices(utterances: $1, events: recorder.events(channel: $0)) }
                .reduce(VoiceScore(), +)
            : nil
        // Voter engines in real-show runs: per-call word errors on the clips
        // they didn't agree on, and on every clip, from this run's lines.
        var nonVoter: (errors: WordErrors, calls: Int)?
        var voterAll: (errors: WordErrors, calls: Int)?
        if let agreeingVoters, let voter = RealShowSet.voter(forEngine: engine.id) {
            func perCall(_ chosen: Set<Int>) -> (errors: WordErrors, calls: Int) {
                scenario.channels.enumerated().reduce((WordErrors(), 0)) { sum, channel in
                    let errors = Scorer.wordErrors(
                        utterances: channel.element, texts: texts, events: recorder.events(channel: channel.offset),
                        clips: chosen
                    )
                    return (sum.0 + errors, sum.1 + channel.element.filter { chosen.contains($0.clip) }.count)
                }
            }
            nonVoter = perCall(Set(agreeingVoters.indices.filter { !agreeingVoters[$0].contains(voter) }))
            voterAll = perCall(Set(agreeingVoters.indices))
        }
        let result = RunResult(
            engine: engine.id,
            channels: count,
            duration: scenario.duration,
            dutyCycle: scenario.dutyCycle,
            speechSeconds: scenario.speechSeconds,
            utterances: scenario.utteranceCount,
            missed: scores.map(\.missed).reduce(0, +),
            wordErrors: scores.map(\.wordErrors).reduce(WordErrors(), +),
            finalLatency: LatencySummary(scores.flatMap(\.finalLatencies)),
            displayLatency: LatencySummary(scores.flatMap(\.displayLatencies)),
            firstWordLatency: LatencySummary(scores.flatMap(\.firstWordLatencies)),
            startSeconds: startSeconds,
            drainSeconds: drainSeconds,
            droppedFrames: rings.map(\.droppedFrames).reduce(0, +),
            processCPU: usage.processCPU,
            systemCPU: usage.systemCPU,
            peakMemoryMB: usage.peakMemoryMB,
            failures: recorder.failures,
            samples: scores.prefix(2).map { RunResult.Sample(reference: $0.reference, hypothesis: $0.hypothesis) },
            displayBacklog: recorder.lastDisplayArrival.map { max(0, $0 - scenario.duration) } ?? 0,
            voices: voices,
            voiceThreshold: engine.detectsVoiceChanges ? voiceChanges.threshold : nil,
            merged: scores.map(\.merged).reduce(0, +),
            longTalk: scenario.longTalk ? true : nil,
            droppedClips: droppedClips,
            diagnosticsRows: diagnosticsRows,
            classifiedRows: classifiedRows,
            nonVoterWordErrors: nonVoter?.errors,
            nonVoterCalls: nonVoter?.calls,
            voterAllWordErrors: voterAll?.errors,
            voterAllCalls: voterAll?.calls
        )
        return keepsTexts ? result : result.numbersOnly()
    }

    /// Share of all cores busy while nothing is being transcribed, so a
    /// run's "CPU (Mac)" can be read against what else the Mac is doing.
    public static func idleSystemCPU(seconds: Double = 5) async -> Double {
        let meter = ResourceMeter()
        try? await Task.sleep(for: .seconds(seconds))
        return meter.finish().systemCPU
    }

    private func allAnswered(_ scenario: Scenario, _ recorder: Recorder) -> Bool {
        let texts = clips.map(\.text)
        return scenario.channels.enumerated().allSatisfy { index, utterances in
            let score = Scorer.score(utterances: utterances, texts: texts, events: recorder.events(channel: index))
            return score.missed == 0 && score.missingAnnotations == 0
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration / .microseconds(1)) / 1_000_000
    }
}

/// Collects events from every channel's transcriber, from any thread.
private final class Recorder: Sendable {
    private struct State {
        var origin: ContinuousClock.Instant?
        var events: [[ObservedEvent]]
        var failures: [Int: String] = [:]
        /// Latest `.complete` or `.recognized` line: when rules last had work.
        var lastRuleArrival: Double?
        /// Latest `.complete` or `.annotated` line: when the screen last changed.
        var lastDisplayArrival: Double?
    }

    private let state: Mutex<State>

    init(channelCount: Int) {
        state = Mutex(State(events: Array(repeating: [], count: channelCount)))
    }

    func begin(at origin: ContinuousClock.Instant) {
        state.withLock { $0.origin = origin }
    }

    func record(_ event: TranscriptionEvent, channel: Int) {
        let now = ContinuousClock.now
        state.withLock { state in
            guard let origin = state.origin else { return }
            let arrival = Double((now - origin) / .microseconds(1)) / 1_000_000
            let observed = ObservedEvent(
                text: event.text, isFinal: event.isFinal, sessionOffset: event.sessionOffset, arrival: arrival,
                lineID: event.lineID, stage: event.stage
            )
            state.events[channel].append(observed)
            if observed.isRuleLine { state.lastRuleArrival = max(state.lastRuleArrival ?? 0, arrival) }
            if observed.isDisplayLine { state.lastDisplayArrival = max(state.lastDisplayArrival ?? 0, arrival) }
        }
    }

    func status(_ status: TranscriberStatus, channel: Int) {
        guard case .failed(let message) = status else { return }
        state.withLock { $0.failures[channel] = message }
    }

    func events(channel: Int) -> [ObservedEvent] { state.withLock { $0.events[channel] } }
    var lastRuleArrival: Double? { state.withLock { $0.lastRuleArrival } }
    var lastDisplayArrival: Double? { state.withLock { $0.lastDisplayArrival } }
    /// Latest final line of any stage.
    var lastArrival: Double? {
        state.withLock { s in [s.lastRuleArrival, s.lastDisplayArrival].compactMap { $0 }.max() }
    }
    var failures: [String] {
        state.withLock { $0.failures.sorted { $0.key < $1.key }.map { "channel \($0.key + 1): \($0.value)" } }
    }
}
