import SwiftUI

/// Opens the post-show report window, from the toolbar or the View menu.
struct ShowReportCommand: View {
    static let windowID = "report"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Report", systemImage: "chart.bar.doc.horizontal") {
            openWindow(id: Self.windowID)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Search and break down this session, or any earlier one")
    }
}
