import Foundation
import WilcoCore

/// Where a transcriber reads audio: a channel's ring, at the capture rate.
public struct AudioSource: Sendable {
    public var ring: AudioRingBuffer
    /// Read each time, since a device can change rate mid-show.
    public var sampleRate: @Sendable () -> Double

    public init(ring: AudioRingBuffer, sampleRate: @escaping @Sendable () -> Double) {
        self.ring = ring
        self.sampleRate = sampleRate
    }
}

/// Everything that decides how a channel is transcribed. A change to any of
/// it restarts that channel's transcriber.
public struct TranscriberConfiguration: Equatable, Sendable {
    public var channelID: UUID
    public var engine: SpeechEngine
    public var localeIdentifier: String
    public var latencyProfile: SpeechLatencyProfile
    public var whisperModel: WhisperModel
    public var vocabulary: [String]
    /// Whisper only; Apple's engines ignore it.
    public var translateToEnglish: Bool

    public init(channel: ChannelConfig, show: ShowDocument) {
        channelID = channel.id
        engine = channel.engine
        localeIdentifier = channel.localeIdentifier
        latencyProfile = channel.latencyProfile
        whisperModel = WhisperModel(rawValue: show.whisperModel) ?? .base
        vocabulary = show.vocabulary(for: channel.id)
        translateToEnglish = channel.translateToEnglish
    }
}

public enum TranscriberStatus: Equatable, Sendable {
    case preparing
    case downloading(progress: Double)
    case listening
    case failed(String)
}

public typealias TranscriptionHandler = @Sendable (TranscriptionEvent) -> Void
public typealias StatusHandler = @Sendable (TranscriberStatus) -> Void

/// Turns one channel's audio into transcription events.
public protocol ChannelTranscriber: Actor {
    func start() async
    func stop() async
}

/// Builds the transcriber a configuration asks for. Apple's engines need
/// macOS 26; on older systems every channel falls back to Whisper.
public enum ChannelTranscribers {
    public static func make(
        configuration: TranscriberConfiguration,
        source: AudioSource,
        sessionOffset: Double,
        whisperModels: WhisperModelStore,
        onEvent: @escaping TranscriptionHandler,
        onStatus: @escaping StatusHandler
    ) -> any ChannelTranscriber {
        if configuration.engine != .whisper, #available(macOS 26, *) {
            return AppleChannelTranscriber(
                configuration: configuration, source: source, sessionOffset: sessionOffset,
                onEvent: onEvent, onStatus: onStatus
            )
        }
        return WhisperChannelTranscriber(
            configuration: configuration, source: source, sessionOffset: sessionOffset,
            models: whisperModels, onEvent: onEvent, onStatus: onStatus
        )
    }
}

/// How often transcribers drain their ring.
let pumpInterval = Duration.milliseconds(100)
