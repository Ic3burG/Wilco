import SwiftUI
import WilcoAudio
import WilcoCore

/// The show's input device, across the top of the sidebar. Channels use it
/// unless their inspector names another device.
struct ShowDevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .help("Input device for the show's channels")
            DevicePicker(
                title: "Device",
                selection: $model.document.deviceUID,
                devices: model.devices,
                fallbackLabel: "System Default Input"
            )
            .labelsHidden()
        }
    }
}
