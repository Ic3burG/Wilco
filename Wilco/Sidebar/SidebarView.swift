import SwiftUI
import WilcoCore
import WilcoTranscription

/// The sidebar: the show's device, the outline of views, folders and
/// channels, and the add buttons.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LookAndFeel.self) private var look

    var body: some View {
        SidebarOutline(
            model: model,
            look: look,
            tree: SidebarTree(model.document),
            selection: model.selection,
            collapsed: look.collapsedGroups
        )
        .overlay {
            if model.document.channels.isEmpty && model.document.groups.isEmpty {
                Text("No channels configured yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ShowDevicePicker()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Channel", systemImage: "plus", action: model.addChannel)
                    .labelStyle(.iconOnly)
                    .help("Add a comms channel")
                Button("New Group", systemImage: "folder.badge.plus", action: model.addGroup)
                    .labelStyle(.iconOnly)
                    .help("Add a group")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

/// One outline row's content, hosted in an AppKit cell. Reads the model
/// itself, so meters and status update without reloading the outline.
struct SidebarRowContent: View {
    @Environment(AppModel.self) private var model
    @Environment(LookAndFeel.self) private var look
    let item: SidebarItem

    var body: some View {
        switch item {
        case .combined:
            Label("Combined", systemImage: "text.bubble")
        case .matrix:
            Label("Matrix", systemImage: "rectangle.split.3x1")
        case .activity:
            Label("Activity", systemImage: "list.bullet.rectangle")
        case .channel(let id):
            if let channel = model.document.channel(id: id) {
                ChannelRow(
                    channel: channel,
                    ownDeviceName: channel.deviceUID.map { model.device(withUID: $0)?.name ?? "not connected" },
                    level: model.meters[channel.id],
                    status: model.transcriberStatus[channel.id]
                )
            }
        case .group(let id):
            if let group = model.document.group(id: id) {
                let members = model.document.channels(inGroup: id)
                GroupRow(
                    group: group,
                    channelCount: members.count,
                    level: look.collapsedGroups.contains(id) ? members.compactMap { model.meters[$0.id] }.max() : nil,
                    isRenaming: model.groupBeingRenamed == id,
                    onRename: { model.document.renameGroup(id: id, to: $0) },
                    onEndRename: { model.groupBeingRenamed = nil }
                )
            }
        }
    }
}

struct ChannelRow: View {
    let channel: ChannelConfig
    /// Set when the channel uses a device other than the show's.
    let ownDeviceName: String?
    /// Meter position while capturing; nil when not captured.
    let level: Float?
    let status: TranscriberStatus?

    var body: some View {
        Label {
            HStack {
                Text(channel.name)
                if let ownDeviceName {
                    Text("(\(ownDeviceName))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Captured from \(ownDeviceName) rather than the show's device")
                }
                Spacer()
                switch status {
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(message)
                case .preparing, .downloading:
                    ProgressView().controlSize(.mini)
                        .help(status?.title ?? "")
                case .listening, nil:
                    EmptyView()
                }
                if let level {
                    LevelMeter(level: level)
                        .frame(width: 36, height: 4)
                }
                if channel.deviceChannel == nil {
                    Image(systemName: "cable.connector.slash")
                        .foregroundStyle(.secondary)
                        .help("Not patched to a hardware input")
                }
                if channel.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.secondary)
                        .help("Muted — audio is captured but not transcribed")
                }
            }
        } icon: {
            Image(systemName: channel.symbol)
                .foregroundStyle(channel.tint.color)
        }
    }
}
