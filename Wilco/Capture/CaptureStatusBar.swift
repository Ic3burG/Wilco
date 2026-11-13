import SwiftUI
import WilcoCore

/// Capture state along the bottom of the window: one entry per device in use.
struct CaptureStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            if model.deviceHealth.isEmpty {
                StateLabel(state: model.isCapturing ? .starting : .stopped, text: nil)
            } else {
                ForEach(devices, id: \.key) { key, health in
                    DeviceStatus(health: health, fallbackName: key.isEmpty ? "System Default Input" : key)
                }
            }
            if reconnects > 0 {
                Label("\(reconnects)", systemImage: "arrow.triangle.2.circlepath")
                    .help("Times an audio device was rebuilt after dropping out")
            }
            if dropped > 0 {
                Label("\(dropped)", systemImage: "exclamationmark.triangle")
                    .help("Audio frames discarded because transcription fell behind")
            }
            Spacer()
            CaptureButton()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var devices: [(key: String, value: CaptureHealth)] {
        model.deviceHealth.sorted { ($0.value.deviceName, $0.key) < ($1.value.deviceName, $1.key) }
    }

    private var reconnects: Int { model.deviceHealth.values.reduce(0) { $0 + $1.recoveryCount } }
    private var dropped: Int { model.deviceHealth.values.reduce(0) { $0 + $1.droppedFrames } }
}

private struct DeviceStatus: View {
    let health: CaptureHealth
    let fallbackName: String

    var body: some View {
        let name = health.deviceName.isEmpty ? fallbackName : health.deviceName
        StateLabel(state: health.state, text: name)
            .help(help(name: name))
    }

    private func help(name: String) -> String {
        var lines = ["\(name): \(health.state.title)"]
        if health.sampleRate > 0 {
            lines.append("\(Int(health.sampleRate)) Hz, \(health.channelCount) inputs")
        }
        if let error = health.lastError { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}

private struct StateLabel: View {
    let state: CaptureState
    /// Device name; nil shows the state alone.
    let text: String?

    var body: some View {
        Label {
            if let text {
                Text(text)
                if state != .running { Text("— \(state.title)") }
            } else {
                Text(state.title)
            }
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(state.color)
        }
        .lineLimit(1)
    }
}

struct CaptureButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isCapturing {
            Button("Stop", systemImage: "stop.circle.fill", action: model.toggleCapture)
                .help("Stop capture and transcription")
        } else {
            Button("Start", systemImage: "record.circle", action: model.toggleCapture)
                .help("Start capture and transcription")
        }
    }
}

extension CaptureState {
    var title: String {
        switch self {
        case .stopped: "Not capturing"
        case .starting: "Starting…"
        case .running: "Capturing"
        case .recovering(let attempt): "Reconnecting (attempt \(attempt))"
        case .failed: "Capture failed"
        }
    }

    var color: Color {
        switch self {
        case .stopped: .gray
        case .starting, .recovering: .orange
        case .running: .green
        case .failed: .red
        }
    }
}
