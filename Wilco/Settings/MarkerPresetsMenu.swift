import SwiftUI
import WilcoCore

/// Save the show's markers as a named preset, or load one as a starting
/// point. Loading copies the preset into the show, so later edits to either
/// never touch the other.
struct MarkerPresetsMenu: View {
    /// Called after a preset replaces the show's markers, so the list can
    /// drop a selection that may no longer exist.
    var onLoad: () -> Void = {}
    @Environment(AppModel.self) private var model
    @State private var presets: [MarkerPreset] = []
    @State private var loading: MarkerPreset?
    @State private var savingSheet = false
    @State private var managingSheet = false
    @State private var errorMessage: String?

    private let store = MarkerPresetStore()

    var body: some View {
        Menu("Presets") {
            Button("Save as Preset…") { savingSheet = true }
            Divider()
            if presets.isEmpty {
                Button("No Saved Presets") {}.disabled(true)
            }
            ForEach(presets) { preset in
                Button(preset.name) { choose(preset) }
            }
            Section("Built-in") {
                ForEach(MarkerPreset.builtIn) { preset in
                    Button(preset.name) { choose(preset) }
                }
            }
            Divider()
            Button("Manage Presets…") { managingSheet = true }
                .disabled(presets.isEmpty)
        }
        .fixedSize()
        .help("Save these markers as a preset, or load one")
        .onAppear(perform: refresh)
        .sheet(isPresented: $savingSheet, onDismiss: refresh) {
            SavePresetSheet(store: store, markers: model.document.markerSettings)
        }
        .sheet(isPresented: $managingSheet, onDismiss: refresh) {
            ManagePresetsSheet(store: store)
        }
        .confirmationDialog(
            "Replace this show's markers with “\(loading?.name ?? "")”?",
            isPresented: Binding(get: { loading != nil }, set: { if !$0 { loading = nil } })
        ) {
            Button("Replace") {
                if let loading { load(loading) }
                loading = nil
            }
        }
        .alert("Wilco", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() {
        presets = store.list()
    }

    /// A show still on the built-in lists has nothing to lose, so it loads at once.
    private func choose(_ preset: MarkerPreset) {
        if model.document.markers == nil {
            load(preset)
        } else {
            loading = preset
        }
    }

    private func load(_ preset: MarkerPreset) {
        // Read again in case the file changed since the menu was built.
        do {
            // Built-ins live in the app; saved presets are read again in case the file changed.
            model.document.markers = preset.isBuiltIn ? preset.markers : try store.preset(preset.id).markers
            onLoad()
        } catch {
            errorMessage = "The “\(preset.name)” preset couldn't be read."
            refresh()
        }
    }
}

/// The message for a preset store error.
private func presetErrorText(_ error: Error) -> String {
    switch error as? ConfigurationError {
    case .emptyName: "A preset needs a name."
    case .nameTaken(let name): "A preset named “\(name)” already exists."
    case .notFound: "That preset no longer exists."
    case nil: error.localizedDescription
    }
}

// MARK: - Save

private struct SavePresetSheet: View {
    let store: MarkerPresetStore
    let markers: MarkerSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var replacing: MarkerPreset?
    @State private var saved = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("e.g. Concert"))
                .onSubmit(attemptSave)
        }
        .formStyle(.grouped)
        .navigationTitle("Save Markers as Preset")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: attemptSave)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 360)
        .confirmationDialog(
            "Replace the “\(replacing?.name ?? "")” preset?",
            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })
        ) {
            // Save now, but close the sheet only once this dialog has gone:
            // dismissing a sheet while its dialog is still closing can be ignored.
            Button("Replace") { saved = save(dismissing: false) }
        }
        .onChange(of: replacing) { _, now in
            if now == nil && saved { dismiss() }
        }
        .alert("Wilco", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func attemptSave() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let existing = store.existing(named: name) {
            replacing = existing
        } else {
            save()
        }
    }

    @discardableResult
    private func save(dismissing: Bool = true) -> Bool {
        do {
            try store.save(name: name, markers: markers)
            if dismissing { dismiss() }
            return true
        } catch {
            errorMessage = presetErrorText(error)
            return false
        }
    }
}

// MARK: - Manage

private struct ManagePresetsSheet: View {
    let store: MarkerPresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [MarkerPreset] = []
    @State private var renaming: MarkerPreset?
    @State private var deleting: MarkerPreset?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(presets) { preset in
                HStack {
                    Text(preset.name)
                    Spacer()
                    Button("Rename") { renaming = preset }
                    Button("Delete", role: .destructive) { deleting = preset }
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if presets.isEmpty {
                ContentUnavailableView("No Presets", systemImage: "flag",
                                       description: Text("Save a show's markers as a preset to see it here."))
            }
        }
        .padding()
        .navigationTitle("Marker Presets")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .frame(width: 360, height: 300)
        .onAppear(perform: refresh)
        .sheet(item: $renaming, onDismiss: refresh) { preset in
            RenamePresetSheet(store: store, preset: preset)
        }
        .confirmationDialog(
            "Delete the “\(deleting?.name ?? "")” preset?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Shows that loaded it keep their own markers.")
        }
        .alert("Wilco", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() {
        presets = store.list()
    }

    private func delete(_ preset: MarkerPreset) {
        do {
            try store.delete(preset.id)
        } catch {
            errorMessage = presetErrorText(error)
        }
        refresh()
    }
}

private struct RenamePresetSheet: View {
    let store: MarkerPresetStore
    let preset: MarkerPreset
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .onSubmit(rename)
        }
        .formStyle(.grouped)
        .navigationTitle("Rename Preset")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename", action: rename)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 360)
        .onAppear { name = preset.name }
        .alert("Wilco", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func rename() {
        do {
            try store.rename(preset.id, to: name)
            dismiss()
        } catch {
            errorMessage = presetErrorText(error)
        }
    }
}
