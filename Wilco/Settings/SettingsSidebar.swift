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
                    SettingsRow(page: page).tag(page)
                }
            }
            Section("This Mac") {
                ForEach(SettingsPage.allCases.filter { $0.area == .mac }) { page in
                    SettingsRow(page: page).tag(page)
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
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                            Text(entry.page.title).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsIcon(page: entry.page)
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
    /// The white symbol on a page's coloured tile in the sidebar.
    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .speech: "text.bubble.fill"
        case .destinations: "paperplane.fill"
        case .rules: "bolt.fill"
        case .markers: "flag.fill"
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .speechModels: "arrow.down"
        case .learning: "graduationcap.fill"
        }
    }

    /// The tile colour, chosen so neighbouring pages differ, as in System Settings.
    var tint: Color {
        switch self {
        case .audio: .red
        case .speech: .blue
        case .destinations: .green
        case .rules: .orange
        case .markers: .purple
        case .general: .gray
        case .appearance: Color(white: 0.15)
        case .speechModels: .teal
        case .learning: .indigo
        }
    }
}

/// A sidebar row: the page's symbol on a coloured rounded tile, then its name.
struct SettingsRow: View {
    let page: SettingsPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            SettingsIcon(page: page)
        }
    }
}

struct SettingsIcon: View {
    let page: SettingsPage

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.tint.gradient))
            .accessibilityHidden(true)
    }
}
