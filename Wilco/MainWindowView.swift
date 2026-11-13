import SwiftUI
import WilcoCore

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(LookAndFeel.self) private var look
    @AppStorage("inspector.visible") private var showsInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            DetailView(item: model.selection)
                .id(model.selection)
                .transition(.opacity)
                .animation(look.animation, value: model.selection)
                .safeAreaInset(edge: .bottom, spacing: 0) { CaptureStatusBar() }
                // On the detail column, not the split view: items there join the
                // narrow sidebar group and spill into the >> overflow menu.
                .toolbar { ToolbarItem { ConfigurationsToolbarButton() } }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { CaptureButton() }
            ToolbarItem { ShowReportCommand() }
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(item: model.selection)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                }
        }
        .navigationTitle(model.windowTitle)
        .toolbarTitleMenu { ConfigurationTitleMenu() }
        .modifier(ConfigurationDialogs())
        // Notice a configuration file removed in Finder while Wilco was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConfigurations()
        }
        .frame(minWidth: 760, minHeight: 480)
        .modifier(ChannelDeletionAlert())
        .alert("Wilco", isPresented: messageIsPresented) {
            Button("OK") {}
        } message: {
            Text(model.lastMessage ?? "")
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { model.lastMessage != nil },
            set: { if !$0 { model.lastMessage = nil } }
        )
    }
}

/// One confirmation for deleting a channel, whether asked from the sidebar,
/// the inspector or the Delete key.
private struct ChannelDeletionAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            Button("Delete Channel", role: .destructive, action: model.confirmDeletion)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel and its on-screen transcript are removed. Lines already written to the transcript file on disk are kept.")
        }
    }

    private var title: String {
        let name = model.channelPendingDeletion.flatMap { model.document.channel(id: $0)?.name } ?? "Channel"
        return "Delete “\(name)”?"
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { model.channelPendingDeletion != nil },
            set: { if !$0 { model.channelPendingDeletion = nil } }
        )
    }
}

private struct DetailView: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .combined:
            TranscriptView(scope: .all)
        case .group(let id):
            TranscriptView(scope: .group(id))
        case .matrix:
            ChannelMatrixView()
        case .activity:
            ActivityLogView()
        case .channel(let id):
            TranscriptView(scope: .channel(id))
        }
    }
}
