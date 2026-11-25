import Foundation
import WilcoCore

/// One session file on disk.
struct SessionFile: Identifiable, Hashable {
    var url: URL
    var modified: Date
    var byteSize: Int
    /// The zone it was recorded in, read from the start of the file.
    var timeZone: TimeZone?

    var id: URL { url }

    /// "Session 2026-11-07 2225-51.jsonl" → the capture start, when the name
    /// allows. The name is wall-clock time in the capture zone.
    var started: Date? { TranscriptFile.started(fromFileName: url, timeZone: timeZone ?? .current) }

    var clock: CaptureClock { CaptureClock(capture: timeZone, at: started ?? modified) }
}

/// The report window: which past session is open and how it is filtered.
@MainActor
@Observable
final class ReportModel {
    enum Tab: String, CaseIterable {
        // Declaration order is the order of the picker in the window.
        case channels = "Channels"
        case log = "Chat log"
        case runOfShow = "Run of show"
        case review = "Review"
    }

    private(set) var sessions: [SessionFile] = []
    var selection: SessionFile.ID? {
        didSet { if selection != oldValue { load() } }
    }
    private(set) var report: ShowReport?
    private(set) var isLoading = false
    private(set) var error: String?

    var tab: Tab = .channels {
        didSet { if tab == .review { loadHistoryIfNeeded() } }
    }

    /// What went wrong in the selected session, against its own show.
    private(set) var review: ShowReview?
    /// Every saved session in summary, newest first; nil until the Review
    /// tab first needs it.
    private(set) var history: [SessionSummary]?
    /// The selected session's lines and the show it was recorded with.
    /// `showIsKnown` is false when the open show stood in for one nobody saved.
    /// What the review is built from, kept until the selection changes.
    private struct ReviewInput {
        var url: URL
        var segments: [TranscriptSegment]
        var show: ShowDocument
        var showIsKnown: Bool
        var diagnostics: SessionDiagnostics?
        var clips: SessionClips?
    }

    /// A session read off disk, ready to show.
    private struct LoadedSession {
        var report: ShowReport
        var reviewInput: ReviewInput
    }

    private var reviewInput: ReviewInput?
    private var reviewTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    /// Findings hidden with Dismiss, as `review.dismissed` keys.
    private(set) var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: ReportModel.dismissedKey) ?? [])
    static let dismissedKey = "review.dismissed"
    var searchText = ""
    /// Channels shown in the run of show and chat log; empty shows all.
    var channelFilter: Set<UUID> = []
    /// The kind of moment shown in the run of show; nil shows everything.
    var categoryFilter: ShowReport.MarkerCategory?
    /// A message the chat log should scroll to.
    var focusedMessage: UUID?

    /// The open show. A session is labelled with the show it was recorded
    /// with; this is the fallback, and wins a tie when guessing for a session
    /// recorded before shows were kept beside transcripts.
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
                return SessionFile(url: url, modified: values?.contentModificationDate ?? .distantPast, byteSize: size,
                                   timeZone: CaptureTimeZone.read(transcript: url, bytes: 16 * 1024))
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

    /// Sessions grouped by the day they started where they were recorded,
    /// newest day first.
    var sessionsByDay: [(day: Date, sessions: [SessionFile])] {
        let groups = Dictionary(grouping: sessions) { session in
            // The capture date's day, as a local midnight for the header.
            var capture = Calendar.current
            capture.timeZone = session.clock.timeZone
            let parts = capture.dateComponents([.year, .month, .day], from: session.started ?? session.modified)
            return Calendar.current.date(from: parts) ?? session.modified
        }
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

    /// Every saved configuration, for guessing an older session's show.
    nonisolated private static func savedShows() -> [ShowDocument] {
        let store = ConfigurationStore()
        return store.list().compactMap { try? store.document($0.id) }
    }

    /// The show name a session's dismissals are kept under.
    var reviewShowName: String {
        guard let input = reviewInput, input.showIsKnown else { return SessionHistory.unknownShow }
        let name = input.show.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? SessionHistory.unknownShow : name
    }

    /// Dismissals belong to the show, so the same finding stays hidden next
    /// time. Vocabulary is keyed by its words, so new names still show.
    func dismissKey(_ finding: Finding) -> String {
        var key = "\(reviewShowName)|\(finding.id)"
        if finding.id == "vocabulary", let review { key += "|" + review.suggestions.map(\.term).sorted().joined(separator: ",") }
        return key
    }

    func dismiss(_ finding: Finding) { setDismissed(dismissed.union([dismissKey(finding)])) }

    func restoreDismissed(_ findings: [Finding]) { setDismissed(dismissed.subtracting(findings.map(dismissKey))) }

    private func setDismissed(_ keys: Set<String>) {
        dismissed = keys
        UserDefaults.standard.set(Array(keys).sorted(), forKey: Self.dismissedKey)
    }

    /// Jumps from a finding to its lines in the chat log.
    func showLines(_ finding: Finding) {
        searchText = ""
        channelFilter = finding.channelID.map { [$0] } ?? []
        tab = .log
        focusedMessage = finding.evidence.first
    }

    private func loadHistoryIfNeeded() {
        guard history == nil, historyTask == nil else { return }
        let show = show
        historyTask = Task {
            let all = await Task.detached(priority: .utility) {
                (try? SessionHistory.summaries(in: DataLocations.transcripts, candidates: [show] + Self.savedShows())) ?? []
            }.value
            history = all
            rebuildReview()
        }
    }

    /// Reviews the selected session against its show and earlier sessions of it.
    private func rebuildReview() {
        reviewTask?.cancel()
        guard let input = reviewInput else { review = nil; return }
        let started = SessionHistory.started(fromFileName: input.url, timeZone: report?.timeZone) ?? .distantFuture
        // Earlier sessions only, so an old session's review doesn't see the future.
        let earlier = SessionHistory.sameShow(as: reviewShowName, in: history ?? [], excluding: input.url)
            .filter { $0.started < started }
        reviewTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                ShowReview.make(segments: input.segments, show: input.show, history: earlier, showIsKnown: input.showIsKnown, diagnostics: input.diagnostics,
                                  clips: input.clips)
            }.value
            // A review finished after the selection moved on belongs to another session.
            guard !Task.isCancelled, reviewInput?.url == input.url else { return }
            review = built
        }
    }

    private func load() {
        loadTask?.cancel()
        reviewTask?.cancel()
        report = nil
        review = nil
        reviewInput = nil
        error = nil
        guard let url = selection else { return }
        isLoading = true
        let show = show
        loadTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                () -> Result<LoadedSession, Error> in
                Result {
                    let segments = TranscriptFile.segments(in: try Data(contentsOf: url))
                    let found = SessionShow.load(forTranscript: url)
                        ?? SessionShow.bestMatch(for: segments, among: [show] + Self.savedShows())
                    let recordedWith = found ?? show
                    let report = ShowReportBuilder.build(segments: segments, show: recordedWith, sourceName: url.lastPathComponent, generated: .now, transcript: url)
                    return LoadedSession(report: report, reviewInput: ReviewInput(
                        url: url, segments: segments, show: recordedWith, showIsKnown: found != nil,
                        diagnostics: SessionDiagnostics.load(forTranscript: url),
                        clips: SessionClips.load(forTranscript: url)))
                }
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch built {
            case .success(let loaded) where loaded.report.totalMessages == 0:
                error = "This session has no transcribed lines."
            case .success(let loaded):
                report = loaded.report
                reviewInput = loaded.reviewInput
                rebuildReview()
            case .failure(let failure):
                error = "Could not read the session: \(failure.localizedDescription)"
            }
        }
    }
}
