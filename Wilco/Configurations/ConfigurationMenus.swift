import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WilcoCore

/// The menu under the window title: every configuration, then Save, Save As
/// New, Revert and Manage.
struct ConfigurationTitleMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.configurations) { configuration in
            Toggle(configuration.name, isOn: Binding(
                get: { configuration.id == model.loadedConfigurationID },
                set: { _ in model.requestLoadConfiguration(configuration.id) }
            ))
            .disabled(model.isCapturing)
        }
        Divider()
        ConfigurationSaveItems()
        Divider()
        ManageConfigurationsButton()
    }
}

/// File menu: the save commands, Configurations…, Import and Export.
struct ConfigurationCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            ConfigurationSaveItems().environment(model)
            Divider()
            ManageConfigurationsButton()
            Button("Import Configuration…") { ConfigurationPanels.importFiles(into: model) }
            Button("Export Configuration…") {
                if let id = model.loadedConfigurationID { ConfigurationPanels.export(id, from: model) }
            }
            .disabled(model.loadedConfigurationID == nil)
        }
    }
}

/// Save ⌘S, Save As New… ⇧⌘S and Revert to Saved.
struct ConfigurationSaveItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Save “\(model.document.name)”") { model.saveConfiguration() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.configurationStatus == .saved)
        Button("Save As New…") { model.isNamingNewConfiguration = true }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        Button("Revert to Saved") { ConfigurationPanels.confirmRevert(model) }
            .disabled(model.configurationStatus != .edited || model.isCapturing)
    }
}

struct ManageConfigurationsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Manage Configurations…") { openWindow(id: ConfigurationsWindow.windowID) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

/// Toolbar button for the Configurations window: one click, always visible.
/// No shortcut here; the menus carry ⇧⌘O.
struct ConfigurationsToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Configurations", systemImage: "rectangle.stack") {
            openWindow(id: ConfigurationsWindow.windowID)
        }
        .help("Configurations: load, save, import and export show setups (⇧⌘O)")
    }
}

/// Open and save panels, and the revert confirmation, shared by the menus
/// and the Configurations window.
@MainActor
enum ConfigurationPanels {
    static let fileType = UTType(filenameExtension: ShowFile.fileExtension) ?? .json

    @discardableResult
    static func importFiles(into model: AppModel) -> [UUID] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Wilco show files to add as configurations."
        guard panel.runModal() == .OK else { return [] }
        return model.importConfigurations(panel.urls)
    }

    static func export(_ id: UUID, from model: AppModel) {
        let name = model.configurations.first { $0.id == id }?.name ?? ConfigurationStore.defaultName
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "\(name).\(ShowFile.fileExtension)"
        if id == model.loadedConfigurationID, model.configurationStatus == .edited {
            panel.message = "This exports the saved version. Save first to include your latest changes."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportConfiguration(id, to: url)
    }

    static func confirmRevert(_ model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Revert “\(model.savedConfiguration?.name ?? model.document.name)” to its saved version?"
        alert.informativeText = "Your changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.revertConfiguration() }
    }
}

/// The unsaved-changes prompt before a load, and the Save As New name sheet.
/// Both the main and Configurations windows carry it; only the active one
/// presents, so a prompt never appears twice.
struct ConfigurationDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .alert(
                pendingLoadTitle,
                isPresented: Binding(
                    get: { appearsActive && model.configurationPendingLoad != nil },
                    set: { if !$0 { model.configurationPendingLoad = nil } }
                )
            ) {
                Button("Save") { model.resolvePendingLoad(saveFirst: true) }
                Button("Don't Save", role: .destructive) { model.resolvePendingLoad(saveFirst: false) }
                Button("Cancel", role: .cancel) { model.configurationPendingLoad = nil }
            } message: {
                Text("Your changes will be lost if you don't save them.")
            }
            .sheet(isPresented: Binding(
                get: { appearsActive && model.isNamingNewConfiguration },
                set: { model.isNamingNewConfiguration = $0 }
            )) {
                SaveAsNewSheet()
            }
    }

    private var pendingLoadTitle: String {
        let target = model.configurations.first { $0.id == model.configurationPendingLoad }?.name ?? "another configuration"
        return "Save changes to “\(model.document.name)” before loading “\(target)”?"
    }
}

private struct SaveAsNewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
        }
        .formStyle(.grouped)
        .navigationTitle("Save As New Configuration")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveConfigurationAsNew(named: name)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 360)
        .onAppear {
            // With no file behind the working copy, keep its name; otherwise suggest a copy.
            name = model.configurationStatus == .notSaved ? model.document.name : "\(model.document.name) copy"
        }
    }
}
