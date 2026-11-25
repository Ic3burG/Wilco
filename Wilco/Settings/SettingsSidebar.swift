import SwiftUI
import WilcoCore

/// The Settings sidebar: show pages in setup order, then this Mac's pages.
/// While searching, it lists the matching settings instead.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPage
    @State private var query = ""

    var body: some View {
        Group {
            if isSearching {
                searchResults
            } else {
                pages
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Settings")
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Pages

    private var pages: some View {
        List(selection: Binding<SettingsPage?>(
            get: { selection },
            set: { if let page = $0 { selection = page } }
        )) {
            Section("This Show") {
                ForEach(SettingsPage.allCases.filter { $0.area == .show }) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            Section("This Mac") {
                ForEach(SettingsPage.allCases.filter { $0.area == .mac }) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsIndex.search(query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results, id: \.self) { entry in
                Button {
                    selection = entry.page
                    query = ""
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        Text(entry.page.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension SettingsPage {
    /// The symbol beside a page in the sidebar.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat.size"
        case .speechModels: "arrow.down.circle"
        case .learning: "graduationcap"
        case .audio: "waveform"
        case .speech: "character.bubble"
        case .destinations: "paperplane"
        case .rules: "bolt"
        case .markers: "flag"
        }
    }
}
