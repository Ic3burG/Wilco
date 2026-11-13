import SwiftUI
import WilcoCore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Look & Feel", systemImage: "textformat.size") {
                LookAndFeelSettingsView()
            }
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView()
                    .frame(width: 540)
            }
            Tab("Languages", systemImage: "character.bubble") {
                LanguagesSettingsView()
                    .frame(width: 600, height: 560)
            }
            Tab("Automation", systemImage: "bolt") {
                AutomationSettingsView()
            }
            Tab("Destinations", systemImage: "paperplane") {
                DestinationSettingsView()
            }
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
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
