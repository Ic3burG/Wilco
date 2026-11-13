import SwiftUI
import WilcoControl
import WilcoCore

enum AutomationSelection: Hashable {
    case rule(AutomationRule.ID)
    case highlight(HighlightRule.ID)
}

/// Rules fire actions when a phrase is heard; highlights only colour the
/// transcript. List on the left, editor on the right.
struct AutomationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AutomationSelection?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
            editor
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
    }

    private var list: some View {
        List(selection: $selection) {
            Section("Rules") {
                ForEach(model.document.rules) { rule in
                    Label(rule.name.isEmpty ? "Untitled Rule" : rule.name,
                          systemImage: rule.isEnabled ? "bolt.fill" : "bolt.slash")
                        .tag(AutomationSelection.rule(rule.id))
                }
            }
            Section("Highlights") {
                ForEach(model.document.highlights) { highlight in
                    Label {
                        Text(highlight.name.isEmpty ? "Untitled Highlight" : highlight.name)
                    } icon: {
                        Image(systemName: "highlighter").foregroundStyle(highlight.tint.color)
                    }
                    .tag(AutomationSelection.highlight(highlight.id))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Rule", action: addRule)
                    Button("New Highlight", action: addHighlight)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a rule or highlight")
                Button("Remove", systemImage: "minus", action: removeSelected)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch selection {
        case .rule(let id):
            if let rule = ruleBinding(id) {
                RuleEditor(
                    rule: rule,
                    channels: model.document.channels,
                    destinations: model.document.destinations,
                    onTest: { model.testRule(id) }
                )
            } else {
                nothingSelected
            }
        case .highlight(let id):
            if let highlight = highlightBinding(id) {
                HighlightEditor(highlight: highlight, channels: model.document.channels)
            } else {
                nothingSelected
            }
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "bolt",
                               description: Text("Rules fire actions when a phrase is heard. Highlights only colour the transcript."))
    }

    // MARK: Editing

    private func addRule() {
        let rule = AutomationRule(name: "New Rule", cooldown: 3)
        model.document.rules.append(rule)
        selection = .rule(rule.id)
    }

    private func addHighlight() {
        let highlight = HighlightRule(name: "New Highlight")
        model.document.highlights.append(highlight)
        selection = .highlight(highlight.id)
    }

    private func removeSelected() {
        let removing = selection
        selection = nil
        switch removing {
        case .rule(let id): model.document.rules.removeAll { $0.id == id }
        case .highlight(let id): model.document.highlights.removeAll { $0.id == id }
        case nil: break
        }
    }

    /// By ID, like channel bindings: a removed rule never indexes a stale position.
    private func ruleBinding(_ id: AutomationRule.ID) -> Binding<AutomationRule>? {
        guard let initial = model.document.rules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.document.rules.first { $0.id == id } ?? initial },
            set: { value in
                guard let index = model.document.rules.firstIndex(where: { $0.id == id }) else { return }
                model.document.rules[index] = value
            }
        )
    }

    private func highlightBinding(_ id: HighlightRule.ID) -> Binding<HighlightRule>? {
        guard let initial = model.document.highlights.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.document.highlights.first { $0.id == id } ?? initial },
            set: { value in
                guard let index = model.document.highlights.firstIndex(where: { $0.id == id }) else { return }
                model.document.highlights[index] = value
            }
        )
    }
}

// MARK: - Rule

private struct RuleEditor: View {
    @Binding var rule: AutomationRule
    let channels: [ChannelConfig]
    let destinations: [OSCDestination]
    let onTest: () -> Void

    @State private var midiDestinations = MIDIOutput.destinations()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.isEnabled)
            }

            Section {
                TokenListEditor(tokens: $rule.phrases, prompt: "Phrase to listen for")
                MatchModePicker(mode: $rule.matchMode)
                ChannelScopePicker(selection: $rule.channelIDs, channels: channels)
            } header: {
                Text("Listen For")
            } footer: {
                Text("Phrases match whole words, ignoring case, punctuation and whether the engine wrote “stand by” or “standby”. Phrases are also biased into the recogniser.")
            }

            Section {
                Stepper(value: $rule.cooldown, in: 0...600, step: 1) {
                    LabeledContent("Cooldown", value: "\(Int(rule.cooldown)) s")
                }
            } footer: {
                Text("Cooldown suppresses repeat fires. Comms traffic repeats constantly, so a rule with no cooldown will fire a cue several times for one spoken standby.")
            }

            Section {
                ForEach(Array(rule.actions.indices), id: \.self) { index in
                    ActionEditor(
                        action: actionBinding(index),
                        destinations: destinations,
                        midiDestinations: midiDestinations,
                        onRemove: { removeAction(at: index) }
                    )
                }
                Menu("Add Action") {
                    Button("OSC Message") {
                        rule.actions.append(.osc(destinationID: destinations.first?.id ?? UUID(),
                                                 address: "/wilco/{channel}/go", arguments: [.string("{text}")]))
                    }
                    .disabled(destinations.isEmpty)
                    Button("MIDI Message") {
                        rule.actions.append(.midi(endpointID: midiDestinations.first?.id ?? 0,
                                                  message: .noteOn(channel: 1, note: 60, velocity: 127)))
                    }
                    Button("Webhook") {
                        rule.actions.append(.webhook(urlTemplate: "http://127.0.0.1:8080/wilco", method: "POST",
                                                     bodyTemplate: #"{"channel":"{channel}","text":"{text}"}"#))
                    }
                    Button("Show Notification") {
                        rule.actions.append(.notify(title: rule.name, bodyTemplate: "Heard on {channel}: {text}"))
                    }
                    Button("Mark Cue Point") {
                        rule.actions.append(.markCuePoint(label: "{keyword}"))
                    }
                }
                .help(destinations.isEmpty ? "Add an OSC destination in Settings › Destinations to send OSC" : "")
            } header: {
                Text("Actions")
            } footer: {
                Text("Placeholders: {text} {channel} {keyword} {time} {offset}")
            }

            Section {
                Button("Test Rule", systemImage: "play.fill", action: onTest)
                    .disabled(rule.actions.isEmpty)
                    .help("Fire this rule's actions now with a sample line")
            }
        }
        .formStyle(.grouped)
        .onAppear { midiDestinations = MIDIOutput.destinations() }
    }

    /// Bounds-checked, so removing an action never reads past the end.
    private func actionBinding(_ index: Int) -> Binding<AutomationAction> {
        let fallback = rule.actions[index]
        return Binding(
            get: { index < rule.actions.count ? rule.actions[index] : fallback },
            set: { if index < rule.actions.count { rule.actions[index] = $0 } }
        )
    }

    private func removeAction(at index: Int) {
        guard index < rule.actions.count else { return }
        rule.actions.remove(at: index)
    }
}

// MARK: - Highlight

private struct HighlightEditor: View {
    @Binding var highlight: HighlightRule
    let channels: [ChannelConfig]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $highlight.name)
                Toggle("Enabled", isOn: $highlight.isEnabled)
                Picker("Colour", selection: $highlight.tint) {
                    ForEach(ChannelTint.allCases, id: \.self) { tint in
                        Label(tint.rawValue.capitalized, systemImage: "circle.fill")
                            .foregroundStyle(tint.color)
                            .tag(tint)
                    }
                }
            }
            Section {
                TokenListEditor(tokens: $highlight.phrases, prompt: "Word or phrase to highlight")
                MatchModePicker(mode: $highlight.matchMode)
                ChannelScopePicker(selection: $highlight.channelIDs, channels: channels)
            } header: {
                Text("Highlight")
            } footer: {
                Text("Matching words are tinted wherever the transcript appears. Phrases listed here are also biased into the recogniser, so they come back spelled correctly.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

private struct MatchModePicker: View {
    @Binding var mode: KeywordMatchMode

    var body: some View {
        Picker("Match", selection: $mode) {
            Text("Contains any phrase").tag(KeywordMatchMode.containsAny)
            Text("Contains all phrases").tag(KeywordMatchMode.containsAll)
            Text("Starts with").tag(KeywordMatchMode.startsWith)
            Text("Matches regular expression").tag(KeywordMatchMode.regularExpression)
        }
    }
}

/// Which channels a rule listens to. None selected means every channel.
private struct ChannelScopePicker: View {
    @Binding var selection: Set<UUID>
    let channels: [ChannelConfig]

    var body: some View {
        DisclosureGroup {
            ForEach(channels) { channel in
                Toggle(isOn: Binding(
                    get: { selection.contains(channel.id) },
                    set: { isOn in
                        if isOn { selection.insert(channel.id) } else { selection.remove(channel.id) }
                    }
                )) {
                    Label(channel.name, systemImage: channel.symbol)
                }
            }
        } label: {
            LabeledContent("Channels", value: summary)
        }
    }

    private var summary: String {
        let chosen = channels.filter { selection.contains($0.id) }
        switch chosen.count {
        case 0: return "All channels"
        case 1: return chosen[0].name
        default: return "\(chosen.count) channels"
        }
    }
}
