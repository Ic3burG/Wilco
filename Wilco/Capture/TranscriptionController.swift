import Foundation
import WilcoAudio
import WilcoCore
import WilcoTranscription

/// Keeps one transcriber running per patched, unmuted channel while capture
/// runs, restarting a channel's transcriber when its settings change.
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
    }

    private var running: [ChannelConfig.ID: Running] = [:]
    private let whisperModels = WhisperModelStore()

    init() {
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

        for (id, configuration) in desired where running[id]?.configuration != configuration {
            guard let ring = capture.ring(for: id) else { continue }
            let updates = continuation
            let transcriber = ChannelTranscribers.make(
                configuration: configuration,
                source: AudioSource(ring: ring, sampleRate: { capture.sampleRate(for: id) }),
                sessionOffset: Date().timeIntervalSince(sessionStart),
                whisperModels: whisperModels,
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
            running[id] = Running(configuration: configuration, transcriber: transcriber, lifecycle: lifecycle)
        }
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
