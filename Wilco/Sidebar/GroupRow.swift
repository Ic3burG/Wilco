import SwiftUI
import WilcoCore

/// A sidebar folder: symbol, name (editable inline), channel count, and,
/// while collapsed, the loudest of its channels' meters.
struct GroupRow: View {
    let group: ChannelGroup
    let channelCount: Int
    /// Loudest member meter while collapsed and capturing; nil hides it.
    let level: Float?
    let isRenaming: Bool
    let onRename: (String) -> Void
    let onEndRename: () -> Void

    var body: some View {
        Label {
            HStack {
                if isRenaming {
                    InlineNameField(prompt: "Group Name", name: group.name, onRename: onRename, onEndRename: onEndRename)
                } else {
                    Text(group.name)
                }
                Spacer()
                if let level {
                    LevelMeter(level: level)
                        .frame(width: 36, height: 4)
                }
                Text(channelCount.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: group.symbol)
        }
    }
}
