import AppKit
import SwiftUI
import WilcoCore
import WilcoTranscription

/// Every speech model download on this Mac: the ones the current show's
/// channels need, and the ones learning uses after a show.
struct SpeechModelsSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var whisperSizes: [WhisperModel: Int64] = [:]
    @State private var parakeetSize: Int64?
    @State private var voiceSize: Int64?
    @State private var parakeetSpeechInstalled: Bool?
    @State private var parakeetVocabularyInstalled = false
    @State private var appleStatus: [ModelInstaller.Item: SpeechAssetStatus] = [:]
    @State private var reserved: [String] = []
    @State private var ultraSize: Int64?
    @State private var sortformerSize: Int64?
    @State private var learningAppleStatus: SpeechAssetStatus?

    /// Clips are labelled with the English long-form model.
    private static let learningLocale = "en-US"
    private static let learningApple = ModelInstaller.Item.apple(.longForm, localeIdentifier: learningLocale)

    var body: some View {
        Form {
            channelModelsSection
            whisperSection
            parakeetSection
            voiceModelSection
            learningSection
        }
        .formStyle(.grouped)
        .task(id: refreshKey) {
            // Re-check now and then too: a channel starting can download a
            // model, and macOS can remove one it no longer needs.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var installer: ModelInstaller { model.installer }

    private var selectedWhisper: WhisperModel {
        WhisperModel(rawValue: model.document.whisperModel) ?? .base
    }

    // MARK: This show's channels

    /// One row per language and engine the show's channels use, plus any
    /// long-form language still reserved that no channel needs any more.
    private struct Requirement: Hashable {
        var engine: SpeechEngine
        var localeIdentifier: String
        var unused = false
    }

    private var requirements: [Requirement] {
        var seen = Set<Requirement>()
        var rows = model.document.channels
            .map { Requirement(engine: $0.engine, localeIdentifier: $0.localeIdentifier) }
            .filter { seen.insert($0).inserted }
        // The language learning labels clips with counts as used too, so
        // installing it under For Learning never offers it for removal here.
        rows += SpeechModelNeeds.unusedLongFormLocales(
            reserved: reserved, channels: model.document.channels, alsoNeeded: [Self.learningLocale]
        )
        .map { Requirement(engine: .longForm, localeIdentifier: $0, unused: true) }
        return rows
    }

    private var channelModelsSection: some View {
        Section {
            if requirements.isEmpty {
                Text("No channels configured yet.").foregroundStyle(.secondary)
            }
            ForEach(requirements, id: \.self) { row in
                LabeledContent {
                    if row.unused {
                        Button("Remove") { installer.remove(.apple(.longForm, localeIdentifier: row.localeIdentifier)) }
                            .help("Tell macOS Wilco no longer needs this language. It is deleted once no other app uses it.")
                    } else if row.engine == .parakeet {
                        parakeetStatus
                    } else if !row.engine.isApple {
                        status(for: .whisper(selectedWhisper), installed: whisperSizes[selectedWhisper] != nil)
                    } else {
                        let item = ModelInstaller.Item.apple(row.engine, localeIdentifier: row.localeIdentifier)
                        status(for: item, apple: appleStatus[item])
                    }
                } label: {
                    Text(languageName(row))
                    Text(row.unused ? "\(row.engine.shortName) · not used by any channel" : row.engine.shortName)
                }
            }
        } header: {
            Text("For This Show's Channels")
        } footer: {
            SettingsFooter("Models run entirely on this Mac — no audio leaves the machine.", more: "Downloading a model ahead of a show avoids a first-utterance delay. Dictation channels reuse the model macOS already installed for keyboard dictation, and every Whisper channel shares the one model below, so per-language downloads apply to the Apple long-form engine.")
        }
    }

    // MARK: Whisper

    private var whisperSection: some View {
        Section {
            LabeledContent {
                status(for: .whisper(selectedWhisper), installed: whisperSizes[selectedWhisper] != nil)
            } label: {
                Text(selectedWhisper.displayName)
                Text("Chosen for this show in Speech")
            }
            // Others on disk, e.g. a model used before switching. Each can be large.
            ForEach(WhisperModel.allCases.filter { $0 != selectedWhisper && whisperSizes[$0] != nil }, id: \.self) { other in
                LabeledContent {
                    Button("Remove") { installer.remove(.whisper(other)) }
                } label: {
                    Text(other.displayName)
                    Text("Not in use · \(whisperSizes[other]!.formatted(.byteCount(style: .file)))")
                }
            }
        } header: {
            Text("Open (Whisper) Model")
        }
    }

    // MARK: Parakeet

    private var parakeetSection: some View {
        Section {
            LabeledContent("Download") { parakeetStatus }
            if let parakeetSize {
                LabeledContent {
                    Button("Remove") { installer.remove(.parakeet) }
                        .disabled(installer.isBusy(.parakeet))
                } label: {
                    Text("On disk")
                    Text(parakeetSize.formatted(.byteCount(style: .file)))
                }
            }
        } header: {
            Text("Parakeet Model")
        } footer: {
            SettingsFooter("Parakeet TDT v3 runs on the Neural Engine.", more: "One model serves every Parakeet channel and detects 25 European languages. Vocabulary applies to English channels, and terms shorter than 3 characters are ignored. ~600 MB with the vocabulary model.")
        }
    }

    /// Installed only when both the speech model and the vocabulary model are
    /// there; a Mac with only the speech model offers the missing download.
    @ViewBuilder
    private var parakeetStatus: some View {
        if parakeetSpeechInstalled == true, !parakeetVocabularyInstalled, installer.progress[.parakeet] == nil {
            HStack {
                if let error = installer.errors[.parakeet] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
                }
                Button("Install Vocabulary Model") { installer.install(.parakeet) }
                    .help("The speech model is installed. This fetches the small model that boosts show vocabulary.")
            }
        } else {
            status(
                for: .parakeet,
                apple: parakeetSpeechInstalled.map { $0 && parakeetVocabularyInstalled ? .installed : .notInstalled }
            )
        }
    }

    // MARK: Voice model

    private var voiceModelSection: some View {
        Section {
            LabeledContent("Voice model") { status(for: .voiceModel, installed: installer.voiceModelInstalled) }
            if installer.voiceModelInstalled {
                LabeledContent {
                    Button("Remove") { installer.remove(.voiceModel) }
                        .disabled(installer.isBusy(.voiceModel))
                } label: {
                    Text("On disk")
                    if let voiceSize { Text(voiceSize.formatted(.byteCount(style: .file))) }
                }
            }
        } header: {
            Text("Voice Changes")
        } footer: {
            Text("Needed by channels that mark voice changes, and by voice grouping below.")
        }
    }

    // MARK: Learning

    /// The models that transcribe kept clips after a show, so their texts can
    /// be compared. Two must agree before a clip counts.
    private var learningSection: some View {
        Section {
            LabeledContent {
                downloadStatus(for: .parakeetUltra, size: ultraSize)
            } label: {
                Text("Parakeet Ultra")
                if let ultraSize { Text(ultraSize.formatted(.byteCount(style: .file))) }
            }
            LabeledContent {
                if learningAppleStatus == .unavailable {
                    Text("Needs macOS 26").foregroundStyle(.secondary)
                } else {
                    status(for: Self.learningApple, apple: learningAppleStatus)
                }
            } label: {
                Text("Apple Long-form")
                Text("English (US)")
            }
            LabeledContent {
                downloadStatus(for: .whisper(.large), size: whisperSizes[.large])
            } label: {
                Text("Whisper large-v3")
                Text(whisperSizes[.large].map { $0.formatted(.byteCount(style: .file)) } ?? "(optional, about 3 GB)")
            }
            LabeledContent {
                downloadStatus(for: .sortformer, size: sortformerSize)
            } label: {
                Text("Voice grouping")
                Text(sortformerSize.map { $0.formatted(.byteCount(style: .file)) } ?? "Sortformer, about 240 MB")
                Text("Groups voices after a show. The voice model above is needed too.")
            }
        } header: {
            Text("For Learning")
        } footer: {
            SettingsFooter("Labelling needs at least two.", more: "A channel's own engine doesn't vote on its clips.")
        }
    }

    // MARK: Status

    @ViewBuilder
    private func status(for item: ModelInstaller.Item, installed: Bool) -> some View {
        status(for: item, apple: installed ? .installed : .notInstalled)
    }

    @ViewBuilder
    private func status(for item: ModelInstaller.Item, apple: SpeechAssetStatus?) -> some View {
        if let fraction = installer.progress[item] {
            progress(fraction)
        } else {
            HStack {
                errorBadge(for: item)
                switch apple {
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notInstalled:
                    Button("Install") { installer.install(item) }
                case .downloading:
                    Text("Downloading…").foregroundStyle(.secondary)
                case .unavailable:
                    Text("Not available").foregroundStyle(.secondary)
                case nil:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func downloadStatus(for item: ModelInstaller.Item, size: Int64?) -> some View {
        if let fraction = installer.progress[item] {
            progress(fraction)
        } else {
            HStack {
                errorBadge(for: item)
                if size != nil {
                    Button("Remove") { installer.remove(item) }
                } else {
                    Button("Download") { installer.install(item) }
                }
            }
        }
    }

    private func progress(_ fraction: Double) -> some View {
        HStack {
            ProgressView(value: fraction).frame(width: 120)
            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
        }
    }

    @ViewBuilder
    private func errorBadge(for item: ModelInstaller.Item) -> some View {
        if let error = installer.errors[item] {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
        }
    }

    // MARK: Refresh

    /// Changes when something the statuses depend on changes.
    private var refreshKey: [String] {
        [model.document.whisperModel, String(installer.generation)]
            + model.document.channels.map { "\($0.engine.rawValue)|\($0.localeIdentifier)" }
    }

    private func refresh() async {
        let store = installer.whisperStore
        whisperSizes = await Task.detached {
            var sizes: [WhisperModel: Int64] = [:]
            for whisper in WhisperModel.allCases { sizes[whisper] = store.sizeOnDisk(of: whisper) }
            return sizes
        }.value
        let parakeet = installer.parakeetStore
        let parakeetState = await Task.detached {
            (parakeet.isInstalled(), parakeet.isVocabularyInstalled(), parakeet.sizeOnDisk())
        }.value
        parakeetSpeechInstalled = parakeetState.0
        parakeetVocabularyInstalled = parakeetState.1
        parakeetSize = parakeetState.2
        let voice = installer.voiceprints
        let voiceState = await Task.detached { (voice.isInstalled(), Self.folderSize(DataLocations.voiceModels)) }.value
        installer.setVoiceModelInstalled(voiceState.0)
        voiceSize = voiceState.0 ? voiceState.1 : nil
        let ultra = installer.parakeetUltraStore
        let sortformer = installer.sortformer
        let learningSizes = await Task.detached { (ultra.sizeOnDisk(), sortformer.sizeOnDisk()) }.value
        ultraSize = learningSizes.0
        sortformerSize = learningSizes.1
        learningAppleStatus = await SpeechAssets.status(engine: .longForm, localeIdentifier: Self.learningLocale)
        reserved = await SpeechAssets.reservedLocaleIdentifiers()
        var statuses: [ModelInstaller.Item: SpeechAssetStatus] = [:]
        for row in requirements where row.engine.isApple && !row.unused {
            statuses[.apple(row.engine, localeIdentifier: row.localeIdentifier)] =
                await SpeechAssets.status(engine: row.engine, localeIdentifier: row.localeIdentifier)
        }
        appleStatus = statuses
    }

    private nonisolated static func folderSize(_ url: URL) -> Int64? {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private func languageName(_ row: Requirement) -> String {
        if row.localeIdentifier.isEmpty, row.engine.isApple {
            return LanguageCatalog.displayName(for: Locale.current.identifier)
        }
        return LanguageCatalog.displayName(for: row.localeIdentifier)
    }
}

private extension SpeechEngine {
    var shortName: String {
        switch self {
        case .longForm: "Long-form"
        case .dictation: "Dictation"
        case .whisper: "Whisper (open)"
        case .parakeet: "Parakeet (open)"
        }
    }
}
