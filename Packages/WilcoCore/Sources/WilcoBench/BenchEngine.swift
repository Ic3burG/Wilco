import Foundation
import Speech
import WilcoCore
import WilcoTranscription

/// What a benchmarked transcriber gets for one channel.
public struct BenchChannel: Sendable {
    /// Zero-based position among the run's channels.
    public var index: Int
    public var id: UUID
    public var source: AudioSource
    public var vocabulary: [String]
    /// For engines that detect voice changes; the others ignore it.
    public var voiceChanges: VoiceChangeSettings
    public var onEvent: TranscriptionHandler
    public var onStatus: StatusHandler
}

/// Builds one channel's transcriber. Made once per run, so channels can share
/// a model the way the app shares one between them.
public typealias BenchChannelFactory = @Sendable (BenchChannel) -> any ChannelTranscriber

/// A speech engine the benchmark can run.
///
/// To try a new model, add an entry to ``builtIn`` whose factory returns a
/// `ChannelTranscriber` for it. The model doesn't need to be in the show
/// format or the app first.
public struct BenchEngine: Sendable {
    /// Short name used on the command line and in reports, e.g. "whisper-base".
    public var id: String
    public var summary: String
    /// Why this engine can't run on this Mac now, or nil when it can.
    public var unavailableReason: @Sendable () async -> String?
    /// Downloads the engine's model, reporting progress from 0 to 1, for
    /// `wilco-bench --install`. Nil when the app installs it instead.
    public var install: (@Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)?
    /// Whether its lines are annotated with voice letters, so runs score
    /// voice changes and the display's delay.
    public var detectsVoiceChanges: Bool
    /// Called at the start of each run.
    public var makeFactory: @Sendable () -> BenchChannelFactory

    public init(
        id: String, summary: String,
        unavailableReason: @escaping @Sendable () async -> String?,
        install: (@Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil,
        detectsVoiceChanges: Bool = false,
        makeFactory: @escaping @Sendable () -> BenchChannelFactory
    ) {
        self.id = id
        self.summary = summary
        self.unavailableReason = unavailableReason
        self.install = install
        self.detectsVoiceChanges = detectsVoiceChanges
        self.makeFactory = makeFactory
    }
}

extension BenchEngine {
    /// Every engine Wilco ships, set up the way a new channel is.
    public static let builtIn: [BenchEngine] = [
        apple(id: "apple-longform", engine: .longForm, profile: .leadAndCorrect,
              summary: "Apple long-form, fast then corrected (the app's default)"),
        apple(id: "apple-longform-single", engine: .longForm, profile: .single,
              summary: "Apple long-form, one pass"),
        apple(id: "apple-dictation", engine: .dictation, profile: .leadAndCorrect,
              summary: "Apple dictation, fast then corrected"),
    ] + WhisperModel.allCases.map(whisper) + parakeet + [
        apple(id: "apple-longform-voices", engine: .longForm, profile: .leadAndCorrect,
              summary: "Apple long-form with voice changes", voices: true),
        whisper(.base, voices: true),
        parakeetVoices,
    ]

    public static func named(_ id: String) -> BenchEngine? {
        builtIn.first { $0.id == id }
    }

    private static func apple(
        id: String, engine: SpeechEngine, profile: SpeechLatencyProfile, summary: String, voices: Bool = false
    ) -> BenchEngine {
        BenchEngine(id: id, summary: summary, unavailableReason: {
            guard #available(macOS 26, *) else { return "needs macOS 26" }
            // Asks what's on the Mac rather than `SpeechAssets.status`, which
            // reports a model as merely "supported" to a process that hasn't
            // reserved it, as this tool hasn't.
            let installed = engine == .dictation
                ? await DictationTranscriber.installedLocales
                : await SpeechTranscriber.installedLocales
            let wanted = Locale(identifier: benchLocale).identifier(.bcp47)
            guard installed.contains(where: { $0.identifier(.bcp47) == wanted }) else {
                return "the \(benchLocale) model isn't installed (Wilco › Settings › Languages)"
            }
            return voices ? voiceModelMissing() : nil
        }, install: voices ? installVoiceModel : nil, detectsVoiceChanges: voices) {
            wilcoFactory(
                engine: engine, profile: profile, whisperModel: .base, models: WhisperModelStore(), voices: voices
            )
        }
    }

    private static func whisper(_ model: WhisperModel) -> BenchEngine { whisper(model, voices: false) }

    private static func whisper(_ model: WhisperModel, voices: Bool) -> BenchEngine {
        BenchEngine(
            id: "whisper-\(model.rawValue)" + (voices ? "-voices" : ""),
            summary: "WhisperKit \(model.rawValue), one model shared by every channel"
                + (voices ? ", with voice changes" : ""),
            unavailableReason: {
                guard WhisperModelStore().isDownloaded(model) else { return "the \(model.rawValue) model isn't downloaded" }
                return voices ? voiceModelMissing() : nil
            },
            install: voices ? installVoiceModel : nil,
            detectsVoiceChanges: voices
        ) {
            // A fresh store per run, so each run pays its own model load.
            wilcoFactory(engine: .whisper, profile: .single, whisperModel: model, models: WhisperModelStore(), voices: voices)
        }
    }

    /// Goes through `ChannelTranscribers.make`, the path the app takes.
    private static func wilcoFactory(
        engine: SpeechEngine, profile: SpeechLatencyProfile, whisperModel: WhisperModel, models: WhisperModelStore,
        voices: Bool
    ) -> BenchChannelFactory {
        // Never loaded: these engines aren't Parakeet, but `make` takes a
        // store. One per run rather than one per channel.
        let parakeetModels = ParakeetModelStore()
        // One voice model for every channel, as the app shares one.
        let voiceprints = voices ? WeSpeakerVoiceprints() : nil
        return { channel in
            var show = ShowDocument()
            show.whisperModel = whisperModel.rawValue
            show.voiceChanges = channel.voiceChanges
            let config = ChannelConfig(
                id: channel.id, name: "Bench \(channel.index + 1)",
                localeIdentifier: benchLocale, engine: engine, latencyProfile: profile,
                detectsVoiceChanges: voices
            )
            var configuration = TranscriberConfiguration(channel: config, show: show)
            configuration.vocabulary = channel.vocabulary
            let transcriber = ChannelTranscribers.make(
                configuration: configuration, source: channel.source, sessionOffset: 0,
                whisperModels: models, parakeetModels: parakeetModels, voiceprints: voiceprints,
                onEvent: channel.onEvent, onStatus: channel.onStatus
            )
            return voiceprints.map { VoiceModelFirst(voiceprints: $0, transcriber: transcriber) } ?? transcriber
        }
    }

    /// Why a `-voices` engine can't run: the voice model isn't on this Mac.
    static func voiceModelMissing() -> String? {
        WeSpeakerVoiceprints().isInstalled()
            ? nil : "the voice model isn't installed (Wilco › Settings, or wilco-bench --install with this engine)"
    }

    static let installVoiceModel: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void = {
        try await WeSpeakerVoiceprints().install(progress: $0)
    }
}

/// Loads the shared voice model before a channel starts, so its load counts
/// in the run's start time (as a speech model's does) rather than in the
/// first lines' display delay.
actor VoiceModelFirst: ChannelTranscriber {
    let voiceprints: WeSpeakerVoiceprints
    let transcriber: any ChannelTranscriber

    init(voiceprints: WeSpeakerVoiceprints, transcriber: any ChannelTranscriber) {
        self.voiceprints = voiceprints
        self.transcriber = transcriber
    }

    func start() async {
        // A model that won't load leaves lines without letters, as in the app.
        try? await voiceprints.prepare()
        await transcriber.start()
    }

    func stop() async { await transcriber.stop() }
}

/// The benchmark's speech is English.
let benchLocale = "en_US"
