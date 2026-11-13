import SwiftUI
import WilcoControl
import WilcoCore

/// Edits one rule action. Each case's fields are bound by rebuilding the
/// enum value, since actions are enums with associated values.
struct ActionEditor: View {
    @Binding var action: AutomationAction
    let destinations: [OSCDestination]
    let midiDestinations: [MIDIDestinationInfo]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Button("Remove Action", systemImage: "trash", role: .destructive, action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            fields
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var fields: some View {
        switch action {
        case .osc(let destinationID, let address, let arguments):
            Picker("Destination", selection: Binding(
                get: { destinationID },
                set: { action = .osc(destinationID: $0, address: address, arguments: arguments) }
            )) {
                ForEach(destinations) { Text($0.name).tag($0.id) }
                if !destinations.contains(where: { $0.id == destinationID }) {
                    Text("Missing destination").tag(destinationID)
                }
            }
            TextField("Address", text: Binding(
                get: { address },
                set: { action = .osc(destinationID: destinationID, address: $0, arguments: arguments) }
            ), prompt: Text("/wilco/{channel}/go"))
            .font(.body.monospaced())
            OSCArgumentsEditor(arguments: Binding(
                get: { arguments },
                set: { action = .osc(destinationID: destinationID, address: address, arguments: $0) }
            ))

        case .midi(let endpointID, let message):
            Picker("Destination", selection: Binding(
                get: { endpointID },
                set: { action = .midi(endpointID: $0, message: message) }
            )) {
                ForEach(midiDestinations) { Text($0.name).tag($0.id) }
                if !midiDestinations.contains(where: { $0.id == endpointID }) {
                    Text("MIDI destination is not connected").tag(endpointID)
                }
            }
            MIDIMessageEditor(message: Binding(
                get: { message },
                set: { action = .midi(endpointID: endpointID, message: $0) }
            ))

        case .webhook(let urlTemplate, let method, let bodyTemplate):
            TextField("URL", text: Binding(
                get: { urlTemplate },
                set: { action = .webhook(urlTemplate: $0, method: method, bodyTemplate: bodyTemplate) }
            ), prompt: Text("http://127.0.0.1:8080/wilco"))
            Picker("Method", selection: Binding(
                get: { method.uppercased() },
                set: { action = .webhook(urlTemplate: urlTemplate, method: $0, bodyTemplate: bodyTemplate) }
            )) {
                ForEach(["POST", "PUT", "GET"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Body", text: Binding(
                get: { bodyTemplate },
                set: { action = .webhook(urlTemplate: urlTemplate, method: method, bodyTemplate: $0) }
            ), axis: .vertical)
            .font(.body.monospaced())
            .lineLimit(2...6)

        case .notify(let title, let bodyTemplate):
            TextField("Title", text: Binding(
                get: { title },
                set: { action = .notify(title: $0, bodyTemplate: bodyTemplate) }
            ))
            TextField("Body", text: Binding(
                get: { bodyTemplate },
                set: { action = .notify(title: title, bodyTemplate: $0) }
            ))

        case .markCuePoint(let label):
            TextField("Label", text: Binding(
                get: { label },
                set: { action = .markCuePoint(label: $0) }
            ), prompt: Text("{keyword}"))
        }
    }

    private var title: String {
        switch action {
        case .osc: "OSC Message"
        case .midi: "MIDI Message"
        case .webhook: "Webhook"
        case .notify: "Show Notification"
        case .markCuePoint: "Mark Cue Point"
        }
    }

    private var symbol: String {
        switch action {
        case .osc: "paperplane"
        case .midi: "pianokeys"
        case .webhook: "network"
        case .notify: "bell"
        case .markCuePoint: "flag"
        }
    }
}

// MARK: - OSC arguments

private struct OSCArgumentsEditor: View {
    @Binding var arguments: [OSCArgument]

    private enum Kind: String, CaseIterable {
        case int = "Int", float = "Float", string = "String", bool = "Bool"
    }

    var body: some View {
        ForEach(Array(arguments.indices), id: \.self) { index in
            HStack {
                Picker("Type", selection: kind(at: index)) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                value(at: index)
                Button("Remove Argument", systemImage: "minus.circle") {
                    if index < arguments.count { arguments.remove(at: index) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        Button("Add Argument", systemImage: "plus") { arguments.append(.string("{text}")) }
            .buttonStyle(.borderless)
    }

    private func argument(at index: Int) -> OSCArgument {
        index < arguments.count ? arguments[index] : .string("")
    }

    private func set(_ value: OSCArgument, at index: Int) {
        if index < arguments.count { arguments[index] = value }
    }

    private func kind(at index: Int) -> Binding<Kind> {
        Binding(
            get: {
                switch argument(at: index) {
                case .int: .int
                case .float: .float
                case .string: .string
                case .bool: .bool
                }
            },
            set: { kind in
                let converted: OSCArgument = switch kind {
                case .int: .int(0)
                case .float: .float(0)
                case .string: .string("{text}")
                case .bool: .bool(true)
                }
                set(converted, at: index)
            }
        )
    }

    @ViewBuilder
    private func value(at index: Int) -> some View {
        switch argument(at: index) {
        case .int(let value):
            TextField("Value", value: Binding(get: { Int(value) }, set: { set(.int(Int32(clamping: $0)), at: index) }), format: .number)
        case .float(let value):
            TextField("Value", value: Binding(get: { Double(value) }, set: { set(.float(Float($0)), at: index) }), format: .number)
        case .string(let value):
            TextField("Value", text: Binding(get: { value }, set: { set(.string($0), at: index) }))
                .font(.body.monospaced())
        case .bool(let value):
            Toggle("True", isOn: Binding(get: { value }, set: { set(.bool($0), at: index) }))
        }
    }
}

// MARK: - MIDI message

private struct MIDIMessageEditor: View {
    @Binding var message: MIDIMessageSpec

    private enum Kind: String, CaseIterable {
        case noteOn = "Note On", noteOff = "Note Off", controlChange = "Control Change"
        case programChange = "Program Change", mscGo = "MSC GO"
    }

    var body: some View {
        Picker("Message", selection: kind) {
            ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        switch message {
        case .noteOn(let channel, let note, let velocity):
            number("Channel", channel, 1...16) { message = .noteOn(channel: $0, note: note, velocity: velocity) }
            number("Note", note, 0...127) { message = .noteOn(channel: channel, note: $0, velocity: velocity) }
            number("Velocity", velocity, 0...127) { message = .noteOn(channel: channel, note: note, velocity: $0) }
        case .noteOff(let channel, let note):
            number("Channel", channel, 1...16) { message = .noteOff(channel: $0, note: note) }
            number("Note", note, 0...127) { message = .noteOff(channel: channel, note: $0) }
        case .controlChange(let channel, let controller, let value):
            number("Channel", channel, 1...16) { message = .controlChange(channel: $0, controller: controller, value: value) }
            number("Controller", controller, 0...127) { message = .controlChange(channel: channel, controller: $0, value: value) }
            number("Value", value, 0...127) { message = .controlChange(channel: channel, controller: controller, value: $0) }
        case .programChange(let channel, let program):
            number("Channel", channel, 1...16) { message = .programChange(channel: $0, program: program) }
            number("Program", program, 0...127) { message = .programChange(channel: channel, program: $0) }
        case .mscGo(let deviceID, let cueNumber, let cueList):
            number("Device ID", deviceID, 0...127) { message = .mscGo(deviceID: $0, cueNumber: cueNumber, cueList: cueList) }
            TextField("Cue Number", text: Binding(get: { cueNumber }, set: { message = .mscGo(deviceID: deviceID, cueNumber: $0, cueList: cueList) }))
            TextField("Cue List", text: Binding(get: { cueList }, set: { message = .mscGo(deviceID: deviceID, cueNumber: cueNumber, cueList: $0) }),
                      prompt: Text("Optional"))
        }
    }

    private func number(_ title: String, _ value: UInt8, _ range: ClosedRange<Int>, set: @escaping (UInt8) -> Void) -> some View {
        Stepper(value: Binding(get: { Int(value) }, set: { set(UInt8(min(max($0, range.lowerBound), range.upperBound))) }), in: range) {
            LabeledContent(title, value: "\(value)")
        }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch message {
                case .noteOn: .noteOn
                case .noteOff: .noteOff
                case .controlChange: .controlChange
                case .programChange: .programChange
                case .mscGo: .mscGo
                }
            },
            set: { kind in
                message = switch kind {
                case .noteOn: .noteOn(channel: 1, note: 60, velocity: 127)
                case .noteOff: .noteOff(channel: 1, note: 60)
                case .controlChange: .controlChange(channel: 1, controller: 1, value: 127)
                case .programChange: .programChange(channel: 1, program: 0)
                case .mscGo: .mscGo(deviceID: 0x7F, cueNumber: "1", cueList: "")
                }
            }
        )
    }
}
