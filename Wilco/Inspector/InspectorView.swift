import SwiftUI
import WilcoCore

struct InspectorView: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .channel(let id):
            ChannelInspector(channelID: id)
        case .group(let id):
            GroupInspector(groupID: id)
        case .combined, .matrix, .activity:
            ShowInspector()
        }
    }
}

private struct ShowInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Show") {
                TextField("Name", text: $model.document.name)
                LabeledContent("Channels", value: model.document.channels.count, format: .number)
            }
            Section {
                TokenListEditor(tokens: $model.document.globalVocabulary, prompt: "Add a term used across the whole show")
            } header: {
                Text("Show Vocabulary")
            } footer: {
                Text("Applied to every channel. Rule phrases are biased in automatically, so there is no need to repeat them here.")
            }
        }
        .formStyle(.grouped)
    }
}
