import Foundation
import WilcoCore

/// One session file on disk.
struct SessionFile: Identifiable, Hashable {
    var url: URL
    var modified: Date
    var byteSize: Int

    var id: URL { url }

    /// "Session 2026-11-07 2225-51.jsonl" → the capture start, when the name allows.
    var started: Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Session ") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm-ss"
        return formatter.date(from: String(name.dropFirst("Session ".count)))
    }
}

/// The report window: which past session is open and how it is filtered.
@MainActor
@Observable
final class ReportModel {
    enum Tab: String, CaseIterable {
        case runOfShow = "Run of show"
        case log = "Chat log"
        case channels = "Channels"
    }

    private(set) var sessions: [SessionFile] = []
    var selection: SessionFile.ID? {
        didSet { if selection != oldValue { load() } }
    }
    private(set) var report: ShowReport?
    private(set) var isLoading = false
    private(set) var error: String?

    var tab: Tab = .runOfShow
    var searchText = ""
    /// Channels shown in the run of show and chat log; empty shows all.
    var channelFilter: Set<UUID> = []
    /// The kind of moment shown in the run of show; nil shows everything.
    var categoryFilter: ShowReport.MarkerCategory?
    /// A message the chat log should scroll to.
    var focusedMessage: UUID?

    /// The show whose channel names and colours label the report.
    var show = ShowDocument()
    private var loadTask: Task<Void, Never>?

    func refresh() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: DataLocations.transcripts, includingPropertiesForKeys: Array(keys)
        )) ?? []
        sessions = urls
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: keys)
                let size = values?.fileSize ?? 0
                guard size > 0 else { return nil }  // a session nobody spoke in
                return SessionFile(url: url, modified: values?.contentModificationDate ?? .distantPast, byteSize: size)
            }
            .sorted { $0.modified > $1.modified }
        if selection == nil || !sessions.contains(where: { $0.id == selection }) {
            selection = sessions.first?.id
        }
    }

    var query: ShowReportSearch.Query { ShowReportSearch.Query(searchText) }

    var filteredMarkers: [ShowReport.Marker] {
        let query = query
        return report?.markers.filter { marker in
            (categoryFilter.map { $0 == marker.category } ?? true)
                && (channelFilter.isEmpty || channelFilter.contains(marker.channelID))
                && (query.isEmpty || query.matches(marker.text))
        } ?? []
    }

    var filteredMessages: [ShowReport.Message] {
        guard let report else { return [] }
        return ShowReportSearch.messages(in: report, matching: searchText, channels: channelFilter)
    }

    /// Sessions grouped by the day they started, newest day first.
    var sessionsByDay: [(day: Date, sessions: [SessionFile])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.started ?? $0.modified) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day, default: []].sorted { ($0.started ?? $0.modified) > ($1.started ?? $1.modified) })
        }
    }

    func toggleChannel(_ id: UUID) {
        if channelFilter.contains(id) { channelFilter.remove(id) } else { channelFilter.insert(id) }
    }

    /// A group chip: all its channels on, or all off if they already were.
    func toggleGroup(_ group: ShowReport.Group) {
        channelFilter = group.toggled(channelFilter)
    }

    /// Jumps from a marker to the line it came from.
    func showInContext(_ marker: ShowReport.Marker) {
        searchText = ""
        tab = .log
        focusedMessage = marker.messageID
    }

    private func load() {
        loadTask?.cancel()
        report = nil
        error = nil
        guard let url = selection else { return }
        isLoading = true
        let show = show
        loadTask = Task {
            let built = await Task.detached(priority: .userInitiated) { () -> Result<ShowReport, Error> in
                Result {
                    let segments = TranscriptFile.segments(in: try Data(contentsOf: url))
                    return ShowReportBuilder.build(segments: segments, show: show, sourceName: url.lastPathComponent, generated: .now)
                }
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch built {
            case .success(let report) where report.totalMessages == 0:
                error = "This session has no transcribed lines."
            case .success(let report):
                self.report = report
            case .failure(let failure):
                error = "Could not read the session: \(failure.localizedDescription)"
            }
        }
    }
}
