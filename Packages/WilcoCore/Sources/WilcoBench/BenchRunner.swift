import Foundation
import Synchronization
import WilcoCore
import WilcoTranscription

/// One recorded call and what was said in it.
public struct BenchClip: Sendable {
    public var text: String
    /// Mono, at the runner's sample rate.
    public var samples: [Float]

    public init(text: String, samples: [Float]) {
        self.text = text
        self.samples = samples
    }

    public func duration(sampleRate: Double) -> Double { Double(samples.count) / sampleRate }
}

/// Plays a scenario into many channels at once, in real time, through the
/// same ring buffers the app's capture fills, and scores what comes back.
public struct BenchRunner: Sendable {
    public var clips: [BenchClip]
    /// The rate the "device" delivers. 48 kHz, like a Dante or MADI interface.
    public var sampleRate: Double
    /// Biased into every channel, as the app biases rule phrases.
    public var vocabulary: [String] = []

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
        let transcribers = (0..<count).map { index in
            factory(BenchChannel(
                index: index, id: UUID(),
                source: AudioSource(ring: rings[index], sampleRate: { rate }),
                vocabulary: vocabulary,
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
        if recorder.failures.isEmpty {
            let tracks = scenario.channels.map {
                ChannelTrack(utterances: $0, clips: clips.map(\.samples), sampleRate: sampleRate)
            }
            let origin = clock.now
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
            // a line or the engine goes quiet.
            while elapsed < scenario.duration + drainTimeout {
                feed(until: elapsed)
                meter.sample()
                if allAnswered(scenario, recorder) { break }
                if elapsed - max(scenario.duration, recorder.lastFinalArrival ?? 0) > Self.quietPeriod { break }
                try? await Task.sleep(for: Self.feedInterval)
                elapsed = seconds(clock.now - origin)
            }
            drainSeconds = max(0, (recorder.lastFinalArrival ?? 0) - scenario.duration)
        }

        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers { group.addTask { await transcriber.stop() } }
        }
        meter.sample()
        let usage = meter.finish()

        let texts = clips.map(\.text)
        let scores = scenario.channels.enumerated().map { index, utterances in
            Scorer.score(utterances: utterances, texts: texts, events: recorder.events(channel: index))
        }
        return RunResult(
            engine: engine.id,
            channels: count,
            duration: scenario.duration,
            dutyCycle: scenario.dutyCycle,
            speechSeconds: scenario.speechSeconds,
            utterances: scenario.utteranceCount,
            missed: scores.map(\.missed).reduce(0, +),
            wordErrors: scores.map(\.wordErrors).reduce(WordErrors(), +),
            finalLatency: LatencySummary(scores.flatMap(\.finalLatencies)),
            firstWordLatency: LatencySummary(scores.flatMap(\.firstWordLatencies)),
            startSeconds: startSeconds,
            drainSeconds: drainSeconds,
            droppedFrames: rings.map(\.droppedFrames).reduce(0, +),
            processCPU: usage.processCPU,
            systemCPU: usage.systemCPU,
            peakMemoryMB: usage.peakMemoryMB,
            failures: recorder.failures,
            samples: scores.prefix(2).map { RunResult.Sample(reference: $0.reference, hypothesis: $0.hypothesis) }
        )
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
            Scorer.score(utterances: utterances, texts: texts, events: recorder.events(channel: index)).missed == 0
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
        var lastFinalArrival: Double?
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
            state.events[channel].append(ObservedEvent(
                text: event.text, isFinal: event.isFinal, sessionOffset: event.sessionOffset, arrival: arrival
            ))
            if event.isFinal { state.lastFinalArrival = max(state.lastFinalArrival ?? 0, arrival) }
        }
    }

    func status(_ status: TranscriberStatus, channel: Int) {
        guard case .failed(let message) = status else { return }
        state.withLock { $0.failures[channel] = message }
    }

    func events(channel: Int) -> [ObservedEvent] { state.withLock { $0.events[channel] } }
    var lastFinalArrival: Double? { state.withLock { $0.lastFinalArrival } }
    var failures: [String] {
        state.withLock { $0.failures.sorted { $0.key < $1.key }.map { "channel \($0.key + 1): \($0.value)" } }
    }
}
