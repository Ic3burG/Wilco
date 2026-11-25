import SwiftUI
import WilcoCore

/// The title and one-line summary at the top of each Settings page, so a
/// newcomer can tell what the page is for before reading its controls.
struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.title).font(.title2.bold())
            Text(page.summary).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
    }
}

extension SettingsPage {
    var summary: String {
        switch self {
        case .audio: "Where this show's sound comes from."
        case .speech: "How this show's channels are transcribed."
        case .destinations: "Consoles and machines rules can send to."
        case .rules: "What happens when a phrase is heard."
        case .markers: "Run-of-show moments the report picks out."
        case .general: "How Wilco behaves on this Mac."
        case .appearance: "How the transcript looks on this Mac."
        case .speechModels: "Downloads shared by every show on this Mac."
        case .learning: "Clips Wilco keeps to learn from your shows."
        }
    }
}
