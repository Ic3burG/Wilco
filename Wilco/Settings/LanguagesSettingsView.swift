import AppKit
import SwiftUI
import WilcoCore
import WilcoTranscription

/// Show vocabulary, the shared Whisper model, and the speech model each
/// channel's language and engine need, with ways to install and remove them.
struct LanguagesSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var whisperSizes: [WhisperModel: Int64] = [:]
    @State private var appleStatus: [ModelInstaller.Item: SpeechAssetStatus] = [:]
    @State private var reserved: [String] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TokenListEditor(tokens: $model.document.globalVocabulary, prompt: "Add a term used across the whole show")
            } header: {
                Text("Global Vocabulary")
            } footer: {
                Text("Applied to every channel. Rule phrases are biased in automatically, so there is no need to repeat them here.")
            }

            whisperSection
            speechModelsSection
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

    // MARK: Whisper

    private var installer: ModelInstaller { model.installer }

    private var selectedWhisper: WhisperModel {
        WhisperModel(rawValue: model.document.whisperModel) ?? .base
    }

    private var whisperSection: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { selectedWhisper },
                set: { model.document.whisperModel = $0.rawValue }
            )) {
                ForEach(WhisperModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Download") {
                status(for: .whisper(selectedWhisper), installed: whisperSizes[selectedWhisper] != nil)
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
        } footer: {
            Text("\(selectedWhisper.blurb) One multilingual model is shared by every channel on the Whisper engine, so this is the only Whisper download — the language is chosen per channel. This is the engine used on macOS earlier than 26.")
        }
    }

    // MARK: Apple and per-channel models

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
        let usedLongForm = Set(rows.filter { $0.engine == .longForm }.map { bcp47($0.localeIdentifier) })
        rows += reserved
            .filter { !usedLongForm.contains(bcp47($0)) }
            .map { Requirement(engine: .longForm, localeIdentifier: $0, unused: true) }
        return rows
    }

    private var speechModelsSection: some View {
        Section {
            if requirements.isEmpty {
                Text("No channels configured yet.").foregroundStyle(.secondary)
            }
            ForEach(requirements, id: \.self) { row in
                LabeledContent {
                    if row.unused {
                        Button("Remove") { installer.remove(.apple(.longForm, localeIdentifier: row.localeIdentifier)) }
                            .help("Tell macOS Wilco no longer needs this language. It is deleted once no other app uses it.")
                    } else if row.engine == .whisper {
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
            Text("Speech Models")
        } footer: {
            Text("Models run entirely on this Mac — no audio leaves the machine. Downloading a model ahead of a show avoids a first-utterance delay. Dictation channels reuse the model macOS already installed for keyboard dictation, and every Whisper channel shares the one model above, so per-language downloads apply to the Apple long-form engine.")
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
            HStack {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        } else {
            HStack {
                if let error = installer.errors[item] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
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
        reserved = await SpeechAssets.reservedLocaleIdentifiers()
        var statuses: [ModelInstaller.Item: SpeechAssetStatus] = [:]
        for row in requirements where row.engine != .whisper && !row.unused {
            statuses[.apple(row.engine, localeIdentifier: row.localeIdentifier)] =
                await SpeechAssets.status(engine: row.engine, localeIdentifier: row.localeIdentifier)
        }
        appleStatus = statuses
    }

    private func languageName(_ row: Requirement) -> String {
        if row.localeIdentifier.isEmpty, row.engine != .whisper {
            return LanguageCatalog.displayName(for: Locale.current.identifier)
        }
        return LanguageCatalog.displayName(for: row.localeIdentifier)
    }

    private func bcp47(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }
}

private extension WhisperModel {
    var displayName: String {
        switch self {
        case .tiny: "Tiny"
        case .base: "Base"
        case .small: "Small"
        case .large: "Large v3"
        }
    }

    /// 0.2.0's descriptions.
    var blurb: String {
        switch self {
        case .tiny: "Fastest, lowest accuracy. ~75 MB. For a busy rig or a slower Mac."
        case .base: "A good balance of speed and accuracy on Apple silicon. ~145 MB."
        case .small: "More accurate, noticeably slower. ~470 MB."
        case .large: "Most accurate, heaviest. ~1.5 GB and slower to a settled line."
        }
    }
}

private extension SpeechEngine {
    var shortName: String {
        switch self {
        case .longForm: "Long-form"
        case .dictation: "Dictation"
        case .whisper: "Whisper (open)"
        }
    }
}
