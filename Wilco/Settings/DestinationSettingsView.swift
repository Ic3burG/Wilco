import SwiftUI
import WilcoCore

/// Consoles and show-control machines that receive OSC.
struct DestinationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.document.destinations.isEmpty {
                Section {
                    Text("No OSC destinations yet. Add one for each console or show-control machine rules should send to.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.document.destinations) { destination in
                if let binding = binding(destination.id) {
                    Section {
                        DestinationForm(destination: binding) {
                            model.document.destinations.removeAll { $0.id == destination.id }
                        }
                    }
                }
            }
            Section {
                Button("Add Destination", systemImage: "plus") {
                    model.document.destinations.append(OSCDestination(name: "Console", host: "127.0.0.1", port: 8000))
                }
            } footer: {
                Text("Removing a destination leaves rules that send to it reporting an error in Activity until they are pointed elsewhere.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }

    private func binding(_ id: OSCDestination.ID) -> Binding<OSCDestination>? {
        guard let initial = model.document.destinations.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.document.destinations.first { $0.id == id } ?? initial },
            set: { value in
                guard let index = model.document.destinations.firstIndex(where: { $0.id == id }) else { return }
                model.document.destinations[index] = value
            }
        )
    }
}

private struct DestinationForm: View {
    @Binding var destination: OSCDestination
    let onRemove: () -> Void

    var body: some View {
        TextField("Name", text: $destination.name)
        TextField("Host", text: $destination.host, prompt: Text("192.168.1.10"))
        TextField("Port", value: port, format: .number.grouping(.never))
        Picker("Transport", selection: $destination.transport) {
            Text("UDP").tag(OSCTransport.udp)
            Text("TCP (length-prefixed)").tag(OSCTransport.tcpLengthPrefixed)
            Text("TCP (SLIP)").tag(OSCTransport.tcpSLIP)
        }
        Toggle("Enabled", isOn: $destination.isEnabled)
        Button("Remove Destination", role: .destructive, action: onRemove)
    }

    private var port: Binding<Int> {
        Binding(
            get: { Int(destination.port) },
            set: { destination.port = UInt16(min(max($0, 1), 65_535)) }
        )
    }
}
