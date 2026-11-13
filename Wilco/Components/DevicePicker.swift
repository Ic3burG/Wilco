import SwiftUI
import WilcoCore

/// Picks an input device by UID. `nil` is the fallback choice, named by
/// `fallbackLabel` (the system default for a show, the show's device for a
/// channel). A chosen device that is unplugged stays selected and is shown
/// as not connected, rather than silently switching to another device.
struct DevicePicker: View {
    let title: String
    @Binding var selection: String?
    let devices: [AudioDeviceInfo]
    let fallbackLabel: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(fallbackLabel).tag(String?.none)
            Divider()
            ForEach(devices) { device in
                Text("\(device.name) — \(device.inputChannels) in").tag(String?.some(device.id))
            }
            if let uid = selection, !devices.contains(where: { $0.id == uid }) {
                Text("\(uid) (not connected)").tag(String?.some(uid))
            }
        }
    }
}
