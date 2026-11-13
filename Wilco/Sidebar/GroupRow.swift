import SwiftUI
import WilcoCore

/// A sidebar folder: symbol, name (editable inline right after it is made),
/// channel count, and, while collapsed, the loudest of its channels' meters.
struct GroupRow: View {
    let group: ChannelGroup
    let channelCount: Int
    /// Loudest member meter while collapsed and capturing; nil hides it.
    let level: Float?
    let isRenaming: Bool
    let onRename: (String) -> Void
    let onEndRename: () -> Void

    @State private var draft = ""
    @FocusState private var nameFocused: Bool
    /// Losing focus commits only once the field has actually had it.
    @State private var hadFocus = false

    var body: some View {
        Label {
            HStack {
                if isRenaming {
                    TextField("Group Name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand(perform: onEndRename)
                        .onChange(of: nameFocused) {
                            if nameFocused { hadFocus = true } else if hadFocus { commit() }
                        }
                        .onAppear {
                            draft = group.name
                            hadFocus = false
                            // A run-loop later: focus set in the same pass as
                            // the List's selection change often doesn't take.
                            Task { @MainActor in nameFocused = true }
                        }
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

    private func commit() {
        onRename(draft)
        onEndRename()
    }
}
