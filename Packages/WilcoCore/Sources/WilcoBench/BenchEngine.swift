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
    /// Called at the start of each run.
    public var makeFactory: @Sendable () -> BenchChannelFactory

    public init(
        id: String, summary: String,
        unavailableReason: @escaping @Sendable () async -> String?,
        install: (@Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil,
        makeFactory: @escaping @Sendable () -> BenchChannelFactory
    ) {
        self.id = id
        self.summary = summary
        self.unavailableReason = unavailableReason
        self.install = install
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
    ] + WhisperModel.allCases.map(whisper) + parakeet

    public static func named(_ id: String) -> BenchEngine? {
        builtIn.first { $0.id == id }
    }

    private static func apple(
        id: String, engine: SpeechEngine, profile: SpeechLatencyProfile, summary: String
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
            return installed.contains { $0.identifier(.bcp47) == wanted }
                ? nil : "the \(benchLocale) model isn't installed (Wilco › Settings › Languages)"
        }) {
            wilcoFactory(engine: engine, profile: profile, whisperModel: .base, models: WhisperModelStore())
        }
    }

    private static func whisper(_ model: WhisperModel) -> BenchEngine {
        BenchEngine(
            id: "whisper-\(model.rawValue)",
            summary: "WhisperKit \(model.rawValue), one model shared by every channel",
            unavailableReason: {
                WhisperModelStore().isDownloaded(model) ? nil : "the \(model.rawValue) model isn't downloaded"
            }
        ) {
            // A fresh store per run, so each run pays its own model load.
            wilcoFactory(engine: .whisper, profile: .single, whisperModel: model, models: WhisperModelStore())
        }
    }

    /// Goes through `ChannelTranscribers.make`, the path the app takes.
    private static func wilcoFactory(
        engine: SpeechEngine, profile: SpeechLatencyProfile, whisperModel: WhisperModel, models: WhisperModelStore
    ) -> BenchChannelFactory {
        { channel in
            var show = ShowDocument()
            show.whisperModel = whisperModel.rawValue
            let config = ChannelConfig(
                id: channel.id, name: "Bench \(channel.index + 1)",
                localeIdentifier: benchLocale, engine: engine, latencyProfile: profile
            )
            var configuration = TranscriberConfiguration(channel: config, show: show)
            configuration.vocabulary = channel.vocabulary
            return ChannelTranscribers.make(
                configuration: configuration, source: channel.source, sessionOffset: 0,
                whisperModels: models, onEvent: channel.onEvent, onStatus: channel.onStatus
            )
        }
    }
}

/// The benchmark's speech is English.
let benchLocale = "en_US"
