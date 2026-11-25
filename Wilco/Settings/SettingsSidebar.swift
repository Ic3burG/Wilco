import SwiftUI
import WilcoCore

/// The Settings sidebar: show pages numbered in setup order with a tick once
/// each looks set up, then this Mac's pages. While searching, it lists the
/// matching settings instead.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPage
    let status: SetupStatus

    @Environment(AppModel.self) private var model
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
                    showRow(page).tag(page)
                }
            }
            Section("This Mac") {
                ForEach(SettingsPage.allCases.filter { $0.area == .mac }) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
        }
    }

    private func showRow(_ page: SettingsPage) -> some View {
        let done = isSetUp(page)
        return HStack(spacing: 8) {
            Text("\(page.setupStep ?? 0)")
                .font(.caption2.bold())
                .monospacedDigit()
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            Text(page.title)
            Spacer(minLength: 4)
            if done {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "\(page.title), set up" : page.title)
    }

    private func isSetUp(_ page: SettingsPage) -> Bool {
        ShowSetupProgress.isSetUp(
            page,
            show: model.document,
            connectedDeviceUIDs: Set(model.devices.map(\.id)),
            isInstalled: status.isInstalled
        )
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
    /// Sidebar symbol for a Mac page; show pages carry their step number.
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
