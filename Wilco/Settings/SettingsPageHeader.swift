import SwiftUI
import WilcoCore

/// The one-line summary at the top of each Settings page, so a newcomer can
/// tell what the page is for before reading its controls. The page's name
/// is in the title bar, as in System Settings.
struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        Text(page.summary)
            .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
