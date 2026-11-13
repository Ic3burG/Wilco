import AVFoundation
import SwiftUI
import WilcoAudio
import WilcoCore
import WilcoTranscription

/// The open show, what the window is showing, the audio capture and its
/// transcript. Edits autosave shortly after they stop, and immediately on quit.
@MainActor
@Observable
final class AppModel {
    private static let selectionKey = "sidebar.selection"

    var document: ShowDocument {
        didSet {
            guard document != oldValue else { return }
            scheduleSave()
            if document.destinations != oldValue.destinations {
                performer.forgetDestinations(except: document.destinations)
            }
            guard let sessionStart else { return }
            if !document.capturesSameInputs(as: oldValue) {
                capture.start(taps: document.captureTaps)
            }
            transcription.reconcile(show: document, capture: capture, sessionStart: sessionStart)
        }
    }

    var selection: SidebarItem {
        didSet { UserDefaults.standard.set(selection.storageValue, forKey: Self.selectionKey) }
    }

    /// Channel awaiting the user's confirmation to delete.
    var channelPendingDeletion: ChannelConfig.ID?

    /// A problem worth telling the user about, such as an unreadable show file.
    var lastMessage: String?

    // MARK: Capture state

    /// Health of each device in use, keyed by UID (empty for the system default).
    private(set) var deviceHealth: [String: CaptureHealth] = [:]
    private(set) var devices: [AudioDeviceInfo] = []
    /// Meter positions, 0...1, for channels being captured.
    private(set) var meters: [ChannelConfig.ID: Float] = [:]

    var isCapturing: Bool { sessionStart != nil }

    // MARK: Transcript state

    private(set) var timeline = TranscriptTimeline()
    /// Per channel while capture runs; absent for channels not transcribed.
    private(set) var transcriberStatus: [ChannelConfig.ID: TranscriberStatus] = [:]
    /// Start of the current capture session; nil when not capturing.
    private(set) var sessionStart: Date?
    /// Chips turned on in each transcript view; empty or absent shows all
    /// of that view's channels. Each view keeps its own.
    var chipFilters: [ChannelScope: Set<ChannelConfig.ID>] = [:]

    // MARK: Automation state

    /// What automation did, newest last. Bounded; this is a live view.
    private(set) var activity: [ActivityEntry] = []
    /// Markers dropped by "Mark Cue Point" actions this session.
    private(set) var markers: [CueMarker] = []

    // MARK: Configuration state (changed only by AppModel+Configurations)

    static let loadedConfigurationKey = "configurations.loaded"
    let configurationStore: ConfigurationStore
    /// Every saved configuration, sorted by name.
    var configurations: [ConfigurationSummary] = []
    /// The configuration the working copy (`document`) was loaded from.
    var loadedConfigurationID: UUID? {
        didSet { UserDefaults.standard.set(loadedConfigurationID?.uuidString, forKey: Self.loadedConfigurationKey) }
    }
    /// The loaded configuration as saved, for the Edited comparison.
    var savedConfiguration: ShowDocument?
    /// A load waiting on the user's Save / Don't Save / Cancel.
    var configurationPendingLoad: UUID?
    /// Set to ask for a name for Save As New.
    var isNamingNewConfiguration = false

    /// The connected device a channel captures from, if it is connected.
    func device(forChannel id: ChannelConfig.ID) -> AudioDeviceInfo? {
        device(withUID: document.deviceUID(for: id))
    }

    /// `nil` resolves to the current system default input.
    func device(withUID uid: String?) -> AudioDeviceInfo? {
        let uid = uid ?? AudioDevices.defaultInputUID()
        return devices.first { $0.id == uid }
    }

    private let store: ShowStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var capture: MultiDeviceCapture!
    @ObservationIgnored private var deviceWatcher: AudioDevices?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private let transcription = TranscriptionController()
    @ObservationIgnored private var writer: TranscriptWriter?
    @ObservationIgnored private var reportedWriteFailure = false
    @ObservationIgnored private var evaluator = AutomationEvaluator()
    @ObservationIgnored private let performer = ActionPerformer()
    /// Speech model downloads started from Settings.
    let installer = ModelInstaller()

    init(store: ShowStore = ShowStore(), configurationStore: ConfigurationStore = ConfigurationStore()) {
        self.store = store
        self.configurationStore = configurationStore
        let loaded = store.load()
        document = loaded.document
        let stored = UserDefaults.standard.string(forKey: Self.selectionKey).flatMap(SidebarItem.init(storageValue:))
        selection = (stored ?? .combined).validated(in: loaded.document)
        if let kept = loaded.recoveredFileURL {
            lastMessage = "Could not open the previous show file. It has been kept at \(kept.path)."
        }

        capture = MultiDeviceCapture { [weak self] health in
            Task { @MainActor in self?.deviceHealth = health }
        }
        deviceWatcher = AudioDevices { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        refreshDevices()

        restoreLoadedConfiguration()

        performer.log = { [weak self] entry in self?.log(entry) }
        performer.mark = { [weak self] marker in self?.markers.append(marker) }

        let updates = transcription.updates
        Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }
    }

    // MARK: Channels

    func addChannel() {
        let engine: SpeechEngine
        if #available(macOS 26, *) { engine = .longForm } else { engine = .whisper }
        let channel = document.addChannel(engine: engine)
        selection = .channel(channel.id)
    }

    // MARK: Groups

    /// The group whose name the sidebar is editing inline.
    var groupBeingRenamed: ChannelGroup.ID?

    /// Makes "New Group", selects it and starts renaming it, as Finder does.
    func addGroup() {
        let group = document.addGroup()
        selection = .group(group.id)
        groupBeingRenamed = group.id
    }

    /// No confirmation: the group's channels are kept, just ungrouped.
    func deleteGroup(_ id: ChannelGroup.ID) {
        if selection == .group(id) { selection = .combined }
        if groupBeingRenamed == id { groupBeingRenamed = nil }
        document.deleteGroup(id: id)
    }

    func requestDeletion(of id: ChannelConfig.ID) {
        channelPendingDeletion = id
    }

    /// Moves the selection off the channel before removing it, so no view is
    /// ever asked to render a channel that no longer exists.
    func confirmDeletion() {
        guard let id = channelPendingDeletion else { return }
        channelPendingDeletion = nil
        if selection == .channel(id) { selection = .combined }
        document.deleteChannel(id: id)
    }

    /// A binding that addresses the channel by ID. Returns `nil` once the
    /// channel is gone; a binding already handed out keeps returning the last
    /// value it saw and ignores writes, rather than indexing a stale position.
    func channelBinding(_ id: ChannelConfig.ID) -> Binding<ChannelConfig>? {
        guard let initial = document.channel(id: id) else { return nil }
        return Binding(
            get: { [weak self] in self?.document.channel(id: id) ?? initial },
            set: { [weak self] value in self?.document.updateChannel(id: id) { $0 = value } }
        )
    }

    // MARK: Capture

    func toggleCapture() {
        if isCapturing {
            stopCapture()
        } else {
            Task { await startCapture() }
        }
    }

    func startCapture() async {
        guard await hasMicrophoneAccess() else {
            lastMessage = "Wilco can't use audio input. Allow it in System Settings › Privacy & Security › Microphone, then start capture again."
            return
        }
        let start = Date()
        sessionStart = start
        writer = TranscriptWriter(url: DataLocations.transcripts.appending(path: TranscriptFile.fileName(for: start)))
        reportedWriteFailure = false
        evaluator.reset()
        capture.start(taps: document.captureTaps)
        transcription.reconcile(show: document, capture: capture, sessionStart: start)
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
    }

    /// Stops listening at once; transcribers finish the line they were
    /// hearing, and it still reaches the session file.
    func stopCapture() {
        sessionStart = nil
        capture.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        meters = [:]
        let transcription = transcription
        Task {
            await transcription.stopAll()
            if sessionStart == nil { writer = nil }
        }
    }

    func clearTranscript(channelID: ChannelConfig.ID? = nil) {
        timeline.clear(channelID: channelID)
    }

    private func apply(_ update: TranscriptionController.Update) {
        switch update {
        case .event(let event):
            let show = document
            let now = Date()
            var firings: [AutomationEvaluator.Firing] = []
            guard let segment = timeline.apply(event, at: now, annotate: { segment in
                segment.highlights = AutomationEvaluator.highlights(for: segment.text, channelID: segment.channelID, in: show)
                firings = evaluator.evaluate(segment, in: show, at: now)
                var seen = Set<String>()
                segment.matchedKeywords = firings.flatMap(\.matched).filter { seen.insert($0.lowercased()).inserted }
            }) else { return }
            do {
                try writer?.append(segment)
            } catch where !reportedWriteFailure {
                reportedWriteFailure = true
                lastMessage = "Could not write the transcript file: \(error.localizedDescription). Lines are still shown on screen."
            } catch {}
            let channelName = show.channel(id: segment.channelID)?.name ?? "Unknown channel"
            for firing in firings {
                let context = TemplateContext(
                    text: segment.text, channel: channelName, keyword: firing.matched.first ?? "",
                    date: segment.timestamp, offset: segment.sessionOffset
                )
                performer.perform(firing.rule, context: context, show: show, channelID: segment.channelID)
            }
        case .status(let channelID, let status):
            transcriberStatus[channelID] = status
        }
    }

    // MARK: Automation

    /// Fires a rule's actions now with a sample line, so it can be checked
    /// against the console without anyone speaking.
    func testRule(_ id: AutomationRule.ID) {
        guard let rule = document.rules.first(where: { $0.id == id }) else { return }
        let channel = rule.channelIDs.lazy.compactMap { self.document.channel(id: $0) }.first ?? document.channels.first
        let keyword = rule.phrases.first ?? ""
        let context = TemplateContext(
            text: keyword.isEmpty ? "Test from Wilco" : "\(keyword) (test from Wilco)",
            channel: channel?.name ?? "Test",
            keyword: keyword,
            date: Date(),
            offset: sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        )
        log(ActivityEntry(kind: .info, ruleName: rule.name, detail: "Test fired"))
        performer.perform(rule, context: context, show: document, channelID: channel?.id)
    }

    func clearActivity() {
        activity = []
    }

    /// Empties the transcript and activity, as loading a different
    /// configuration does. Lines already written to disk stay. Cue markers
    /// are kept: they exist only in memory, so clearing them would lose them.
    func clearLiveViews() {
        timeline.clear(channelID: nil)
        activity = []
    }

    private func log(_ entry: ActivityEntry) {
        activity.append(entry)
        if activity.count > 1_000 { activity.removeFirst(activity.count - 1_000) }
    }

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    private func hasMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Shows the loudest peak since the last update; falls back gently so
    /// short peaks stay visible. Never shows more than the signal reached.
    private func updateMeters() {
        let fallPerUpdate: Float = 0.04
        var next: [ChannelConfig.ID: Float] = [:]
        for (id, peak) in capture.takePeaks() {
            next[id] = max(LevelMath.meterPosition(peak), (meters[id] ?? 0) - fallPerUpdate)
        }
        meters = next
    }

    // MARK: Saving

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try store.save(document)
        } catch {
            lastMessage = "Could not save the show: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
