import SwiftUI
import WilcoCore
import WilcoTranscription

/// Edits one channel, found by ID on every render.
///
/// 0.2.0 stored the channel's array index here, and crashed when a
/// delete shortened the array while this view was still on screen.
struct ChannelInspector: View {
    @Environment(AppModel.self) private var model
    let channelID: ChannelConfig.ID

    var body: some View {
        if let channel = model.channelBinding(channelID) {
            ChannelForm(
                channel: channel,
                groups: model.document.groups,
                devices: model.devices,
                showDeviceName: model.device(withUID: model.document.deviceUID)?.name ?? "System Default Input",
                inputNames: model.device(forChannel: channelID)?.channelNames,
                level: model.meters[channelID],
                status: model.transcriberStatus[channelID],
                onAssignGroup: { model.document.assignChannel(channelID, toGroup: $0) },
                onNewGroup: {
                    let group = model.document.addGroup()
                    model.document.assignChannel(channelID, toGroup: group.id)
                    model.groupBeingRenamed = group.id
                },
                onClear: { model.clearTranscript(channelID: channelID) },
                onDelete: { model.requestDeletion(of: channelID) }
            )
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.trailing")
        }
    }
}

private struct ChannelForm: View {
    @Binding var channel: ChannelConfig
    let groups: [ChannelGroup]
    let devices: [AudioDeviceInfo]
    let showDeviceName: String
    /// The channel's device's input names, or nil when it isn't connected.
    let inputNames: [String]?
    let level: Float?
    let status: TranscriberStatus?
    /// Group changes go through the model so channel order stays in sidebar order.
    let onAssignGroup: (ChannelGroup.ID?) -> Void
    let onNewGroup: () -> Void
    let onClear: () -> Void
    let onDelete: () -> Void

    @State private var languageOptions: [LanguageOption] = []

    /// Picker tag standing for "New Group…"; never a real group's ID.
    private static let newGroupTag = UUID()

    /// The channel's group as the picker sees it: a group that no longer
    /// exists reads as None.
    private var groupSelection: Binding<UUID?> {
        Binding(
            get: { groups.contains { $0.id == channel.groupID } ? channel.groupID : nil },
            set: { $0 == Self.newGroupTag ? onNewGroup() : onAssignGroup($0) }
        )
    }

    private let symbols = ["person.wave.2", "headphones", "lightbulb", "speaker.wave.2", "video", "theatermasks", "music.mic"]

    var body: some View {
        Form {
            Section("Channel") {
                TextField("Name", text: $channel.name)
                Picker("Colour", selection: $channel.tint) {
                    ForEach(ChannelTint.allCases, id: \.self) { tint in
                        Label(tint.rawValue.capitalized, systemImage: "circle.fill")
                            .foregroundStyle(tint.color)
                            .tag(tint)
                    }
                }
                Picker("Symbol", selection: $channel.symbol) {
                    ForEach(symbols, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                Picker("Group", selection: groupSelection) {
                    Text("None").tag(UUID?.none)
                    ForEach(groups) { Label($0.name, systemImage: $0.symbol).tag(UUID?.some($0.id)) }
                    Divider()
                    Text("New Group…").tag(UUID?.some(Self.newGroupTag))
                }
            }

            Section {
                DevicePicker(
                    title: "Device",
                    selection: $channel.deviceUID,
                    devices: devices,
                    fallbackLabel: "Show device (\(showDeviceName))"
                )
                Picker("Hardware Channel", selection: $channel.deviceChannel) {
                    Text("Not patched").tag(Int?.none)
                    ForEach(Array(inputLabels.enumerated()), id: \.offset) { index, label in
                        Text(label).tag(Int?.some(index))
                    }
                    if let patched = channel.deviceChannel, patched >= inputLabels.count {
                        Text("Input \(patched + 1) (not on this device)").tag(Int?.some(patched))
                    }
                }
                .help("Which input on the capture device feeds this channel")
                if let level {
                    LabeledContent("Level") {
                        LevelMeter(level: level).frame(height: 6)
                    }
                }
                Toggle("Mute transcription", isOn: $channel.isMuted)
            } header: {
                Text("Input")
            } footer: {
                Text("A muted channel keeps capturing audio and metering, but stops feeding the recogniser.")
            }

            Section("Recognition") {
                if let status {
                    LabeledContent("Status", value: status.title)
                }
                Picker("Engine", selection: $channel.engine) {
                    ForEach(SpeechEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Language", selection: languageSelection) {
                    ForEach(languageOptions) { Text($0.name).tag($0.id) }
                    if !languageOptions.contains(where: { $0.id == languageSelection.wrappedValue }) {
                        // Shown until the list loads, or for a language this engine lacks.
                        Text(LanguageCatalog.displayName(for: channel.localeIdentifier))
                            .tag(languageSelection.wrappedValue)
                    }
                }
                .help(channel.engine == .whisper
                      ? "Whisper can detect the spoken language itself, or be told which to expect"
                      : "Apple's engines need to be told which language to expect")
                if channel.engine == .whisper {
                    Toggle("Translate to English", isOn: Binding(
                        get: { channel.translateToEnglish },
                        set: { channel.setTranslateToEnglish($0) }
                    ))
                    .help("Whisper writes this channel's transcript in English, whatever language is spoken. Turning it on sets the language to Detect Automatically; pick a language instead if you know what will be spoken.")
                }
                Picker("Latency", selection: $channel.latencyProfile) {
                    Text("Fast, then corrected").tag(SpeechLatencyProfile.leadAndCorrect)
                    Text("Single pass").tag(SpeechLatencyProfile.single)
                }
                .disabled(channel.engine == .whisper)
                .help("A quick model shows words as they are spoken; an accurate one replaces them a moment later. Roughly twice the CPU per channel.")
            }

            Section {
                TokenListEditor(tokens: $channel.vocabulary, prompt: "Add a name, cue label or piece of jargon")
            } header: {
                Text("Channel Vocabulary")
            } footer: {
                Text("Terms listed here are biased into this channel's recogniser. Crew names, venue names and cue labels are the ones worth adding.")
            }

            Section {
                Button("Clear This Channel's Transcript", action: onClear)
                    .help("Lines already written to the transcript file on disk are kept")
                Button("Delete Channel…", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .task(id: channel.engine) {
            languageOptions = await LanguageCatalog.options(for: channel.engine)
        }
        .onChange(of: channel.engine) { _, engine in
            // Only Whisper can detect the language, so pick one for Apple's engines.
            if engine != .whisper, channel.localeIdentifier.isEmpty {
                channel.localeIdentifier = Locale.current.identifier
            }
        }
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                LanguageCatalog.selection(
                    for: channel.localeIdentifier, engine: channel.engine, in: languageOptions
                )
            },
            set: { channel.localeIdentifier = $0 }
        )
    }

    /// "1: Dante 1"-style labels from the device, or numbered inputs when
    /// the device isn't connected so a patch can still be set up offline.
    private var inputLabels: [String] {
        guard let inputNames else { return (1...64).map { "Input \($0)" } }
        return inputNames.enumerated().map { index, name in
            name == "Input \(index + 1)" ? name : "\(index + 1): \(name)"
        }
    }
}

private extension SpeechEngine {
    var displayName: String {
        switch self {
        case .longForm: "Long-form (macOS 26)"
        case .dictation: "Dictation (macOS 26)"
        case .whisper: "Whisper"
        }
    }
}
