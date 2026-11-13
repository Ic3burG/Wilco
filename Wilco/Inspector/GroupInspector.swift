import SwiftUI
import WilcoCore

/// Symbols offered for a group, in the inspector and the folder's context menu.
enum GroupSymbols {
    static let all = [
        "folder", "antenna.radiowaves.left.and.right", "rectangle.3.group", "theatermasks",
        "video", "lightbulb", "music.mic", "headphones",
    ]
}

/// Edits one sidebar group, found by ID on every render.
struct GroupInspector: View {
    @Environment(AppModel.self) private var model
    let groupID: ChannelGroup.ID
    /// What the name field shows; blank names are never saved.
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let group = model.document.group(id: groupID) {
            let members = model.document.channels(inGroup: groupID)
            Form {
                Section("Group") {
                    TextField("Name", text: $draftName)
                        .focused($nameFocused)
                        .onChange(of: draftName) { model.document.renameGroup(id: groupID, to: draftName) }
                        // Follow renames made elsewhere (inline in the sidebar)
                        // unless the user is typing here.
                        .onChange(of: group.name) { if !nameFocused { draftName = group.name } }
                    Picker("Symbol", selection: symbol(of: group)) {
                        ForEach(GroupSymbols.all, id: \.self) { Image(systemName: $0).tag($0) }
                    }
                }
                Section {
                    if members.isEmpty {
                        Text("Drag channels onto this folder, or choose it as a channel's group.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(members) { channel in
                        Label {
                            Text(channel.name)
                        } icon: {
                            Image(systemName: channel.symbol).foregroundStyle(channel.tint.color)
                        }
                    }
                } header: {
                    Text("Channels")
                } footer: {
                    Text("Groups only change what you see. Every channel is still captured and transcribed.")
                }
            }
            .formStyle(.grouped)
            .task(id: groupID) { draftName = group.name }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.trailing")
        }
    }

    private func symbol(of group: ChannelGroup) -> Binding<String> {
        Binding(
            get: { group.symbol },
            set: { model.document.setGroupSymbol(id: groupID, $0) }
        )
    }
}
