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
/// it restarts that channel's transcriber, except the voice settings' values:
/// running channels take those through
/// ``ChannelTranscriber/updateVoiceSettings(_:)``.
public struct TranscriberConfiguration: Equatable, Sendable {
    public var channelID: UUID
    public var engine: SpeechEngine
    public var localeIdentifier: String
    public var latencyProfile: SpeechLatencyProfile
    public var whisperModel: WhisperModel
    public var vocabulary: [String]
    /// Whisper only; Apple's engines ignore it.
    public var translateToEnglish: Bool
    /// Whether the channel detects voice changes. Turning it on or off
    /// restarts the channel.
    public var detectsVoiceChanges: Bool
    /// The show's voice settings as the channel starts. Not part of equality,
    /// so moving a voice setting doesn't restart every channel (cutting the
    /// line in progress and starting the exchange again at A).
    public var voiceSettings: VoiceChangeSettings {
        get { startingVoiceSettings.value }
        set { startingVoiceSettings.value = newValue }
    }
    private var startingVoiceSettings: Uncompared<VoiceChangeSettings>

    /// The voice settings, or `nil` when the channel does not detect voice changes.
    public var voiceChanges: VoiceChangeSettings? { detectsVoiceChanges ? voiceSettings : nil }

    public init(channel: ChannelConfig, show: ShowDocument) {
        channelID = channel.id
        engine = channel.engine
        localeIdentifier = channel.localeIdentifier
        latencyProfile = channel.latencyProfile
        whisperModel = WhisperModel(rawValue: show.whisperModel) ?? .base
        vocabulary = show.vocabulary(for: channel.id)
        translateToEnglish = channel.translateToEnglish
        detectsVoiceChanges = channel.detectsVoiceChanges
        startingVoiceSettings = Uncompared(value: show.voiceChanges)
    }
}

/// A value carried in an `Equatable` type without counting towards its
/// equality: any two compare equal.
struct Uncompared<Value: Sendable>: Equatable, Sendable {
    var value: Value
    static func == (_: Self, _: Self) -> Bool { true }
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
    /// New voice settings for a running channel, used from its next line on.
    /// The exchange so far and its letters are kept. Ignored by a channel
    /// that doesn't detect voice changes.
    func updateVoiceSettings(_ settings: VoiceChangeSettings) async
}

/// Builds the transcriber a configuration asks for. Apple's engines need
/// macOS 26; on older systems every channel falls back to Whisper.
///
/// `voiceprints` is the app's one voice model, shared by every channel that
/// detects voice changes. Nil (or a model that isn't installed) leaves those
/// channels' lines without letters; it never stops them transcribing.
public enum ChannelTranscribers {
    public static func make(
        configuration: TranscriberConfiguration,
        source: AudioSource,
        sessionOffset: Double,
        whisperModels: WhisperModelStore,
        parakeetModels: ParakeetModelStore,
        voiceprints: (any VoiceprintExtractor)?,
        onEvent: @escaping TranscriptionHandler,
        onStatus: @escaping StatusHandler
    ) -> any ChannelTranscriber {
        if configuration.engine == .parakeet {
            return UtteranceChannelTranscriber(
                channelID: configuration.channelID, source: source, sessionOffset: sessionOffset,
                recognizer: ParakeetRecognizer(
                    store: parakeetModels, language: ParakeetLanguages.language(for: configuration.localeIdentifier),
                    vocabulary: configuration.vocabulary
                ),
                voiceChanges: configuration.voiceChanges, voiceprints: voiceprints,
                onEvent: onEvent, onStatus: onStatus
            )
        }
        if configuration.engine.isApple, #available(macOS 26, *) {
            return AppleChannelTranscriber(
                configuration: configuration, source: source, sessionOffset: sessionOffset,
                voiceprints: voiceprints, onEvent: onEvent, onStatus: onStatus
            )
        }
        return WhisperChannelTranscriber(
            configuration: configuration, source: source, sessionOffset: sessionOffset,
            models: whisperModels, voiceprints: voiceprints, onEvent: onEvent, onStatus: onStatus
        )
    }
}

/// How often transcribers drain their ring.
let pumpInterval = Duration.milliseconds(100)
