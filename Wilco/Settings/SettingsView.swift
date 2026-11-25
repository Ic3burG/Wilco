import SwiftUI
import WilcoCore

struct SettingsView: View {
    /// Every tab shares one size so the window doesn't jump when switching
    /// tabs. Sized for the list-and-editor tabs (Automation, Markers); the
    /// shorter forms scroll inside it.
    static let size = CGSize(width: 860, height: 600)

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView().settingsPane()
            }
            Tab("Look & Feel", systemImage: "textformat.size") {
                LookAndFeelSettingsView().settingsPane()
            }
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView().settingsPane()
            }
            Tab("Speech", systemImage: "character.bubble") {
                SpeechSettingsView().settingsPane()
            }
            Tab("Speech Models", systemImage: "arrow.down.circle") {
                SpeechModelsSettingsView().settingsPane()
            }
            Tab("Learning", systemImage: "graduationcap") {
                LearningSettingsView().settingsPane()
            }
            Tab("Automation", systemImage: "bolt") {
                AutomationSettingsView().settingsPane()
            }
            Tab("Markers", systemImage: "flag") {
                MarkerSettingsView().settingsPane()
            }
            Tab("Destinations", systemImage: "paperplane") {
                DestinationSettingsView().settingsPane()
            }
        }
    }
}

private extension View {
    func settingsPane() -> some View {
        frame(width: SettingsView.size.width, height: SettingsView.size.height)
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
                Text("Quit is ⌥⌘Q. The show on screen is always kept and reopens as you left it; this asks whether to write your changes into the loaded configuration too. It only asks when the title says Edited or Not Saved.")
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
                Text("Channels use the show's device unless their inspector names another, so several interfaces can be captured at once. Devices are matched by UID, so unplugging and replugging one restores the same patch.")
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
                Text("Wilco drives the audio device directly and watches for it going quiet. If the driver stalls or the interface is unplugged, capture is rebuilt automatically.")
            }
        }
        .formStyle(.grouped)
    }
}
