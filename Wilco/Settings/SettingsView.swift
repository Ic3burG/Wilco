import SwiftUI
import WilcoCore

struct SettingsView: View {
    @AppStorage(SettingsPage.storageKey) private var storedPage = SettingsPage.audio.rawValue
    @State private var history = NavigationHistory<SettingsPage>()
    /// The page Back or Forward just moved to, so that move isn't recorded
    /// as a new visit.
    @State private var stepTarget: SettingsPage?

    private var selection: Binding<SettingsPage> {
        Binding(
            get: { SettingsPage.restored(from: storedPage) },
            set: { storedPage = $0.rawValue }
        )
    }

    var body: some View {
        // The sidebar always shows, as in System Settings: no collapse button,
        // and dragging the divider can't hide it.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(selection: selection)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                SettingsPageHeader(page: selection.wrappedValue)
                detail(for: selection.wrappedValue)
            }
            .navigationTitle(selection.wrappedValue.title)
            .toolbar {
                ToolbarItem(placement: .navigation) { backForward }
            }
        }
        // Any page change counts: sidebar, search, or another window opening
        // Settings at a page.
        .onChange(of: storedPage) { old, new in
            let from = SettingsPage.restored(from: old)
            let to = SettingsPage.restored(from: new)
            if stepTarget == to {
                stepTarget = nil
            } else {
                history.visit(from: from, to: to)
            }
        }
        .background(UnifiedToolbarWindow())
        // Sidebar plus the 860-wide content area the pages were laid out for.
        .frame(minWidth: 1060, minHeight: 640)
    }

    /// Back and forward arrows joined in one capsule, left of the page title,
    /// as in System Settings. ⌘[ and ⌘] work too.
    private var backForward: some View {
        ControlGroup {
            Button("Back", systemImage: "chevron.backward") { step(back: true) }
                .disabled(!history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("See the previous page")
            Button("Forward", systemImage: "chevron.forward") { step(back: false) }
                .disabled(!history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("See the next page")
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
    }

    private func step(back: Bool) {
        let current = selection.wrappedValue
        let target = back ? history.goBack(from: current) : history.goForward(from: current)
        guard let target, target != current else { return }
        stepTarget = target
        storedPage = target.rawValue
    }

    @ViewBuilder
    private func detail(for page: SettingsPage) -> some View {
        switch page {
        case .audio: AudioSettingsView()
        case .speech: SpeechSettingsView()
        case .destinations: DestinationSettingsView()
        case .rules: AutomationSettingsView()
        case .markers: MarkerSettingsView()
        case .general: GeneralSettingsView()
        case .appearance: LookAndFeelSettingsView()
        case .speechModels: SpeechModelsSettingsView()
        case .learning: LearningSettingsView()
        }
    }
}

private struct AudioSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                DevicePicker(
                    title: "Show Device",
                    selection: $model.document.deviceUID,
                    devices: model.devices,
                    fallbackLabel: "System Default Input"
                )
                Button("Refresh Devices", systemImage: "arrow.clockwise", action: model.refreshDevices)
                    .help("Look again for connected audio devices")
            } footer: {
                SettingsFooter("Channels use the show's device unless their inspector names another, so several interfaces can be captured at once.", more: "Devices are matched by UID, so unplugging and replugging one restores the same patch.")
            }

            Section {
                if model.deviceHealth.isEmpty {
                    LabeledContent("State", value: CaptureState.stopped.title)
                }
                ForEach(model.deviceHealth.sorted { $0.key < $1.key }, id: \.key) { key, health in
                    LabeledContent(health.deviceName.isEmpty ? (key.isEmpty ? "System Default Input" : key) : health.deviceName) {
                        VStack(alignment: .trailing) {
                            Text(health.state.title)
                            if health.recoveryCount > 0 {
                                Text("\(health.recoveryCount) reconnects this session")
                            }
                            if let error = health.lastError {
                                Text(error).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Capture")
            } footer: {
                SettingsFooter("Wilco drives the audio device directly and watches for it going quiet.", more: "If the driver stalls or the interface is unplugged, capture is rebuilt automatically.")
            }
        }
        .formStyle(.grouped)
    }
}
