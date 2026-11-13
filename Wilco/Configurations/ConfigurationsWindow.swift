import SwiftUI
import WilcoCore

/// Every saved configuration: load, add, duplicate, rename, delete, import
/// and export.
struct ConfigurationsWindow: View {
    static let windowID = "configurations"

    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @State private var selection: UUID?
    @State private var renaming: ConfigurationSummary?
    @State private var deleting: ConfigurationSummary?

    var body: some View {
        VStack(spacing: 0) {
            Table(model.configurations, selection: $selection) {
                TableColumn("Name") { configuration in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .opacity(configuration.id == model.loadedConfigurationID ? 1 : 0)
                            .accessibilityLabel(configuration.id == model.loadedConfigurationID ? "Loaded" : "")
                        Text(configuration.name)
                    }
                }
                TableColumn("Channels") { Text("\($0.channelCount)").monospacedDigit() }
                    .width(70)
                TableColumn("Saved") {
                    Text($0.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { model.requestLoadConfiguration(id) }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 520, minHeight: 320)
        // Inside the view, so it sees the AppModel the scene injects.
        .modifier(ConfigurationDialogs())
        .onAppear(perform: model.refreshConfigurations)
        .sheet(item: $renaming) { RenameSheet(configuration: $0) }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { model.deleteConfiguration(deleting.id) }
                deleting = nil
            }
        } message: {
            Text("This can't be undone.")
        }
        // Problems from this window's actions (a name already taken, an
        // unreadable import) show here while it's the active window.
        .alert("Wilco", isPresented: Binding(
            get: { appearsActive && model.lastMessage != nil },
            set: { if !$0 { model.lastMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.lastMessage ?? "")
        }
    }

    private var selected: ConfigurationSummary? {
        model.configurations.first { $0.id == selection }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button("New", systemImage: "plus") { selection = model.newConfiguration() }
                .labelStyle(.iconOnly)
                .help("New blank configuration")
            Button("Duplicate") { if let selection { self.selection = model.duplicateConfiguration(selection) } }
                .disabled(selected == nil)
            Button("Rename…") { renaming = selected }
                .disabled(selected == nil)
            Button("Delete…") { deleting = selected }
                .disabled(selected == nil || selection == model.loadedConfigurationID)
                .help(selection == model.loadedConfigurationID ? "The loaded configuration can't be deleted" : "")
            Spacer()
            Button("Import…") { selection = ConfigurationPanels.importFiles(into: model).first ?? selection }
            Button("Export…") { if let selection { ConfigurationPanels.export(selection, from: model) } }
                .disabled(selected == nil)
            Button("Save Changes") { model.saveConfiguration() }
                .disabled(model.configurationStatus == .saved)
                .help(model.configurationStatus == .saved
                    ? "No unsaved changes"
                    : "Save your changes into “\(model.document.name)” (⌘S)")
            Button("Load") { if let selection { model.requestLoadConfiguration(selection) } }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || model.isCapturing || selection == model.loadedConfigurationID)
                .help(model.isCapturing ? "Stop capture before loading a different configuration" : "")
        }
        .padding(10)
    }
}

private struct RenameSheet: View {
    let configuration: ConfigurationSummary
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
        }
        .formStyle(.grouped)
        .navigationTitle("Rename Configuration")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") {
                    model.renameConfiguration(configuration.id, to: name)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 360)
        .onAppear { name = configuration.name }
    }
}
