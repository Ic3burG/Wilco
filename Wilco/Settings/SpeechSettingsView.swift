import SwiftUI
import WilcoCore
import WilcoTranscription

/// How this show's channels are transcribed: vocabulary, what new channels
/// start on, which Whisper model the show uses, and voice-change tuning.
/// Everything here is saved in the show; downloads are in Speech Models.
struct SpeechSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newChannelLanguages: [LanguageOption] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VocabularySummaryRow(terms: $model.document.globalVocabulary)
            } header: {
                Text("Global Vocabulary")
            } footer: {
                Text("Applied to every channel. Rule phrases are biased in automatically, so there is no need to repeat them here.")
            }

            newChannelSection
            whisperSection
            voiceSection
        }
        .formStyle(.grouped)
    }

    // MARK: New channels

    private var newChannelSection: some View {
        Section {
            Picker("Engine", selection: Binding(
                get: { model.document.newChannelEngine },
                set: { model.document.defaultEngine = $0 }
            )) {
                ForEach(SpeechEngine.selectable, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Language", selection: newChannelLanguage) {
                ForEach(newChannelLanguages) { Text($0.name).tag($0.id) }
                if !newChannelLanguages.contains(where: { $0.id == newChannelLanguage.wrappedValue }) {
                    // Shown until the list loads, or for a language this engine lacks.
                    Text(LanguageCatalog.displayName(for: newChannelLanguage.wrappedValue))
                        .tag(newChannelLanguage.wrappedValue)
                }
            }
            .task(id: model.document.newChannelEngine) {
                newChannelLanguages = await LanguageCatalog.options(for: model.document.newChannelEngine)
            }
        } header: {
            Text("New Channels")
        } footer: {
            Text("The engine and language a channel starts on when it is added to this show. Existing channels keep their own; change one in its inspector. Apple's engines offer regional English (United Kingdom, Australia and others); Whisper and Parakeet have one English.")
        }
    }

    private var newChannelLanguage: Binding<String> {
        Binding(
            get: {
                let engine = model.document.newChannelEngine
                return LanguageCatalog.selection(
                    for: model.document.newChannelLocale(for: engine), engine: engine, in: newChannelLanguages
                )
            },
            set: { model.document.defaultLocaleIdentifier = $0 }
        )
    }

    // MARK: Whisper

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
        } header: {
            Text("Open (Whisper) Model")
        } footer: {
            Text("\(selectedWhisper.blurb) One multilingual model is shared by every channel on the Whisper engine, so this is the only Whisper download — the language is chosen per channel. This is the engine used on macOS earlier than 26.")
        }
    }

    // MARK: Voice changes

    private var voiceSection: some View {
        @Bindable var model = model
        return Section {
            LabeledContent("Telling voices apart") {
                HStack {
                    Text("Stricter").foregroundStyle(.secondary)
                    Slider(value: $model.document.voiceChanges.threshold, in: 0.3...0.7)
                        .frame(width: 160)
                    Text("Looser").foregroundStyle(.secondary)
                    Text(model.document.voiceChanges.threshold.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Stepper(
                "New exchange after \(Int(model.document.voiceChanges.exchangeGap)) s",
                value: $model.document.voiceChanges.exchangeGap, in: 5...60, step: 1
            )
            Button("Restore Defaults") { model.document.voiceChanges = .standard }
                .disabled(model.document.voiceChanges == .standard)
        } header: {
            Text("Voice Changes")
        } footer: {
            Text("Letters mark who is speaking within one exchange, not who they are. Voiceprints are kept in memory only and never saved. The voice model is a download in Speech Models.")
        }
    }
}

extension WhisperModel {
    var displayName: String {
        switch self {
        case .tiny: "Tiny"
        case .base: "Base"
        case .small: "Small"
        case .large: "Large v3"
        }
    }

    var blurb: String {
        switch self {
        case .tiny: "Fastest, lowest accuracy. ~75 MB. For a busy rig or a slower Mac."
        case .base: "A good balance of speed and accuracy on Apple silicon. ~145 MB."
        case .small: "More accurate, noticeably slower. ~470 MB."
        case .large: "Most accurate, heaviest. ~1.5 GB and slower to a settled line."
        }
    }
}
