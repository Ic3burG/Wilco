import SwiftUI
import WilcoCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsPage.storageKey) private var storedPage = SettingsPage.audio.rawValue
    @State private var status = SetupStatus()

    private var selection: Binding<SettingsPage> {
        Binding(
            get: { SettingsPage.restored(from: storedPage) },
            set: { storedPage = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: selection, status: status)
        } detail: {
            VStack(spacing: 0) {
                SettingsPageHeader(page: selection.wrappedValue)
                detail(for: selection.wrappedValue)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: statusKey) {
            // The Speech tick follows downloads made here or by a channel
            // starting, so check again now and then while Settings is open.
            while !Task.isCancelled {
                await status.refresh(for: model.document, installer: model.installer)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var statusKey: [String] {
        [model.document.whisperModel, String(model.installer.generation)]
            + model.document.channels.map { "\($0.engine.rawValue)|\($0.localeIdentifier)" }
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

private struct GeneralSettingsView: View {
    @AppStorage(AppModel.asksToSaveOnQuitKey) private var asksToSaveOnQuit = true

    var body: some View {
        Form {
            Section {
                Toggle("Ask to save configuration changes when quitting", isOn: $asksToSaveOnQuit)
            } header: {
                Text("Quitting")
            } footer: {
                SettingsFooter("Quit is ⌥⌘Q.", more: "The show on screen is always kept and reopens as you left it; this asks whether to write your changes into the loaded configuration too. It only asks when the title says Edited or Not Saved.")
            }
        }
        .formStyle(.grouped)
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
