import Foundation
import WilcoAudio
import WilcoCore
import WilcoTranscription

/// Keeps one transcriber running per patched, unmuted channel while capture
/// runs, restarting a channel's transcriber when its settings change. Voice
/// settings are the exception: running channels take new ones in place.
@MainActor
final class TranscriptionController {
    enum Update: Sendable {
        case event(TranscriptionEvent)
        case status(ChannelConfig.ID, TranscriberStatus?)
    }

    /// Everything transcribers report, in the order they reported it. A
    /// single stream keeps a volatile line from overtaking its final line.
    let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation

    private struct Running {
        var configuration: TranscriberConfiguration
        var transcriber: any ChannelTranscriber
        /// Start, and any stop of a predecessor, in order. A ring has one reader.
        var lifecycle: Task<Void, Never>
        /// Parakeet's models on disk as the transcriber was made, so an
        /// install can tell which channels started without one.
        var startedWith: ParakeetAvailability
        /// The voice settings sent to the running transcriber, in order, so a
        /// quick run of slider moves can't land out of order.
        var voiceUpdate: Task<Void, Never>?
    }

    private var running: [ChannelConfig.ID: Running] = [:]
    private let whisperModels = WhisperModelStore()
    private let parakeetModels: ParakeetModelStore
    /// The voice model, loaded once and shared by every channel that detects
    /// voice changes. Until it's installed, their lines go out without letters.
    private let voiceprints: WeSpeakerVoiceprints

    init(parakeetModels: ParakeetModelStore, voiceprints: WeSpeakerVoiceprints) {
        self.parakeetModels = parakeetModels
        self.voiceprints = voiceprints

        (updates, continuation) = AsyncStream.makeStream()
    }

    func reconcile(show: ShowDocument, capture: MultiDeviceCapture, sessionStart: Date) {
        var desired: [ChannelConfig.ID: TranscriberConfiguration] = [:]
        for channel in show.channels where channel.deviceChannel != nil && !channel.isMuted {
            desired[channel.id] = TranscriberConfiguration(channel: channel, show: show)
        }

        for (id, entry) in running where desired[id] == nil {
            running[id] = nil
            let previous = entry
            Task {
                await previous.lifecycle.value
                await previous.transcriber.stop()
            }
            continuation.yield(.status(id, nil))
        }

        // Voice settings reach running channels without a restart, which
        // would cut the line in progress and start the exchange again at A.
        for (id, configuration) in desired {
            guard var entry = running[id], entry.configuration == configuration,
                  entry.configuration.voiceSettings != configuration.voiceSettings
            else { continue }
            entry.configuration = configuration
            if configuration.detectsVoiceChanges {
                let transcriber = entry.transcriber
                let settings = configuration.voiceSettings
                let previous = entry.voiceUpdate
                entry.voiceUpdate = Task {
                    await previous?.value
                    await transcriber.updateVoiceSettings(settings)
                }
            }
            running[id] = entry
        }

        for (id, configuration) in desired where running[id]?.configuration != configuration {
            start(id, configuration, capture: capture, sessionStart: sessionStart)
        }
    }

    /// After a model was installed, restarts only the Parakeet channels it
    /// helps: ones that failed for want of the speech model, and ones running
    /// unboosted because the vocabulary model was missing when they started.
    /// Healthy channels keep running.
    func modelsInstalled(
        statuses: [ChannelConfig.ID: TranscriberStatus], capture: MultiDeviceCapture, sessionStart: Date
    ) {
        let now = ParakeetAvailability(store: parakeetModels)
        for (id, entry) in running where ModelArrival.restarts(
            entry.configuration, status: statuses[id], startedWith: entry.startedWith, now: now
        ) {
            start(id, entry.configuration, capture: capture, sessionStart: sessionStart)
        }
    }

    /// Starts a channel's transcriber, after stopping the one it replaces.
    private func start(
        _ id: ChannelConfig.ID, _ configuration: TranscriberConfiguration,
        capture: MultiDeviceCapture, sessionStart: Date
    ) {
        guard let ring = capture.ring(for: id) else { return }
        let updates = continuation
        let startedWith = ParakeetAvailability(store: parakeetModels)
        let transcriber = ChannelTranscribers.make(
            configuration: configuration,
            source: AudioSource(ring: ring, sampleRate: { capture.sampleRate(for: id) }),
            sessionOffset: Date().timeIntervalSince(sessionStart),
            whisperModels: whisperModels,
            parakeetModels: parakeetModels,
            voiceprints: voiceprints,
            onEvent: { updates.yield(.event($0)) },
            onStatus: { updates.yield(.status(id, $0)) }
        )
        let previous = running[id]
        let lifecycle = Task {
            if let previous {
                await previous.lifecycle.value
                await previous.transcriber.stop()
            }
            await transcriber.start()
        }
        running[id] = Running(
            configuration: configuration, transcriber: transcriber, lifecycle: lifecycle, startedWith: startedWith
        )
    }

    /// Stops every transcriber, letting each finish the line it was hearing.
    /// They stop side by side, so one slow to stop (still loading a model,
    /// say) can't leave the others reading audio into the next session.
    func stopAll() async {
        let all = running
        running = [:]
        let updates = continuation
        await withTaskGroup(of: Void.self) { group in
            for (id, entry) in all {
                group.addTask {
                    await entry.lifecycle.value
                    await entry.transcriber.stop()
                    updates.yield(.status(id, nil))
                }
            }
        }
    }
}
