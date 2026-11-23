import SwiftUI
import WilcoCore

private enum MarkerSelection: Hashable {
    case label(MarkerLabel.ID)
    case countdown
    case songStart
    case departments
}

/// The phrases the post-show report uses to mark show phases, house lights,
/// songs, cue calls and department gos, for this show. List on the left,
/// editor on the right, like Automation.
struct MarkerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MarkerSelection?
    @State private var confirmingRestore = false

    /// Reads the built-in lists until the show has its own; the first edit
    /// stores the whole set in the show.
    private var settings: Binding<MarkerSettings> {
        Binding(
            get: { model.document.markerSettings },
            set: { model.document.markers = $0 }
        )
    }

    private static let labelCategories: [ShowReport.MarkerCategory] = [.phase, .houseLights, .song, .cue, .talkback]

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
                .padding([.leading, .vertical], 20)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
        .confirmationDialog("Restore the built-in markers?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) {
                selection = nil
                model.document.markers = nil
            }
        } message: {
            Text("This show's marker lists are replaced with Wilco's built-in ones.")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(ShowReport.MarkerCategory.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(settings.wrappedValue.labels(in: category)) { label in
                            Label(label.name.isEmpty ? "Untitled Label" : label.name,
                                  systemImage: label.isEnabled ? "flag.fill" : "flag.slash")
                                .tag(MarkerSelection.label(label.id))
                        }
                        .onMove { source, destination in
                            settings.wrappedValue.moveLabels(in: category, fromOffsets: source, toOffset: destination)
                        }
                        builtInRows(for: category)
                    }
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            HStack(spacing: 4) {
                Menu {
                    ForEach(Self.labelCategories, id: \.self) { category in
                        Button("New Label in \(category.title)") { addLabel(to: category) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a marker label")
                Button("Remove", systemImage: "minus", action: removeSelected)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(selectedLabelID == nil)
                Spacer()
                MarkerPresetsMenu(onLoad: { selection = nil })
                Button("Restore Defaults…") { confirmingRestore = true }
                    .disabled(model.document.markers == nil)
                    .help("Go back to Wilco's built-in marker lists for this show")
            }
            .padding(.vertical, 6)
            Text("Reports use the markers saved with the show a session was recorded with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func builtInRows(for category: ShowReport.MarkerCategory) -> some View {
        switch category {
        case .phase:
            builtInRow("Countdown", enabled: settings.wrappedValue.countdownEnabled).tag(MarkerSelection.countdown)
        case .song:
            builtInRow("Song start", enabled: settings.wrappedValue.songStartEnabled).tag(MarkerSelection.songStart)
        case .department:
            builtInRow("Departments", enabled: settings.wrappedValue.departmentGosEnabled).tag(MarkerSelection.departments)
        case .houseLights, .cue, .talkback:
            EmptyView()
        }
    }

    private func builtInRow(_ title: String, enabled: Bool) -> some View {
        Label(title, systemImage: enabled ? "wand.and.stars" : "flag.slash")
    }

    @ViewBuilder
    private var editor: some View {
        switch selection {
        case .label(let id):
            if let label = labelBinding(id) {
                // A fresh editor per label, so a half-typed phrase isn't added to the next one.
                LabelEditor(label: label)
                    .id(id)
            } else {
                nothingSelected
            }
        case .countdown:
            BuiltInEditor(title: "Countdown", isOn: settings.countdownEnabled,
                          footer: "Marks calls like “5 minutes to doors” or “we're at 10 minutes”.")
        case .songStart:
            BuiltInEditor(title: "Song start", isOn: settings.songStartEnabled,
                          footer: "Marks calls like “top of the next song” or “playback rolling”.")
        case .departments:
            DepartmentsEditor(isOn: settings.departmentGosEnabled, departments: settings.departments)
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "flag",
                               description: Text("Markers are the run-of-show moments a post-show report picks out of comms."))
    }

    // MARK: Editing

    private var selectedLabelID: MarkerLabel.ID? {
        if case .label(let id) = selection { id } else { nil }
    }

    private func addLabel(to category: ShowReport.MarkerCategory) {
        let label = MarkerLabel(category: category, name: "New Label")
        var updated = settings.wrappedValue
        // After the category's last label, so it sits at the bottom of its section.
        let index = updated.labels.lastIndex { $0.category == category }.map { $0 + 1 } ?? updated.labels.endIndex
        updated.labels.insert(label, at: index)
        settings.wrappedValue = updated
        selection = .label(label.id)
    }

    private func removeSelected() {
        guard let id = selectedLabelID else { return }
        selection = nil
        settings.wrappedValue.labels.removeAll { $0.id == id }
    }

    /// By ID, like rule bindings: a removed label never indexes a stale position.
    private func labelBinding(_ id: MarkerLabel.ID) -> Binding<MarkerLabel>? {
        guard let initial = settings.wrappedValue.labels.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { settings.wrappedValue.labels.first { $0.id == id } ?? initial },
            set: { value in
                var updated = settings.wrappedValue
                guard let index = updated.labels.firstIndex(where: { $0.id == id }) else { return }
                updated.labels[index] = value
                settings.wrappedValue = updated
            }
        )
    }
}

// MARK: - Editors

private struct LabelEditor: View {
    @Binding var label: MarkerLabel

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label.name)
                Toggle("Enabled", isOn: $label.isEnabled)
            }
            Section {
                TokenListEditor(tokens: $label.phrases, prompt: "Add a phrase, e.g. house to half")
            } header: {
                Text("Listen For")
            } footer: {
                Text("Whole words, any letter case. Labels are checked top to bottom; the first match in a category wins.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BuiltInEditor: View {
    let title: String
    @Binding var isOn: Bool
    let footer: String

    var body: some View {
        Form {
            Section {
                Toggle(title, isOn: $isOn)
            } footer: {
                Text(footer)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DepartmentsEditor: View {
    @Binding var isOn: Bool
    @Binding var departments: [String]

    var body: some View {
        Form {
            Section {
                Toggle("Department Gos", isOn: $isOn)
            }
            Section {
                TokenListEditor(tokens: $departments, prompt: "Add a department, e.g. rigging")
            } header: {
                Text("Departments")
            } footer: {
                Text("Matches “rigging go” and “go rigging”. “Cue 12 go” is matched even with no departments listed.")
            }
        }
        .formStyle(.grouped)
    }
}
