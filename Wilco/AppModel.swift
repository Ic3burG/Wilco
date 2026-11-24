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
    static let createdDatesBackfilledKey = "configurations.createdDatesBackfilled"
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
    @ObservationIgnored private let transcription: TranscriptionController
    @ObservationIgnored private var writer: TranscriptWriter?
    /// One sound classifier for the app's lifetime; each session's recorder shares it.
    @ObservationIgnored private let soundClassifier = SoundClassifierQueue()
    @ObservationIgnored private var diagnostics: DiagnosticsRecorder?
    /// Keeps short audio clips beside the session when the preference was on at capture start.
    @ObservationIgnored private var clipKeeper: ClipKeeper?
    /// When capture last stopped; labelling waits a while after this.
    private(set) var lastCaptureStop: Date?
    @ObservationIgnored private var reportedWriteFailure = false
    @ObservationIgnored private var evaluator = AutomationEvaluator()
    /// Keywords of recognised lines, kept until their annotated pieces arrive.
    @ObservationIgnored private var pendingLines = PendingLines()
    @ObservationIgnored private let performer = ActionPerformer()
    /// Speech model downloads started from Settings.
    let installer: ModelInstaller
    /// Labels kept clips after shows, when nothing is capturing.
    @ObservationIgnored private(set) var learning: LearningController!

    init(store: ShowStore = ShowStore(), configurationStore: ConfigurationStore = ConfigurationStore()) {
        // One Parakeet store for Settings and running channels, so a removed model is seen by both.
        let parakeetModels = ParakeetModelStore()
        // Likewise one voice model, so Settings and channels agree on whether it is installed.
        let voiceprints = WeSpeakerVoiceprints()
        // Parakeet Ultra labels kept clips; it shares the live model's vocabulary model.
        let parakeetUltraModels = ParakeetModelStore(
            directory: DataLocations.parakeetUltraModels, version: .ultra,
            vocabularyDirectory: DataLocations.parakeetModels
        )
        installer = ModelInstaller(
            parakeetStore: parakeetModels, parakeetUltraStore: parakeetUltraModels, voiceprints: voiceprints
        )
        transcription = TranscriptionController(parakeetModels: parakeetModels, voiceprints: voiceprints)
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

        installer.onInstalled = { [weak self] in
            self?.modelsInstalled()
            self?.learning.check()
        }
        performer.log = { [weak self] entry in self?.log(entry) }
        performer.mark = { [weak self] marker in self?.markers.append(marker) }

        let updates = transcription.updates
        Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }

        learning = LearningController(
            ultra: installer.parakeetUltraStore, whisper: installer.whisperStore,
            isCapturing: { [weak self] in self?.isCapturing ?? true },
            lastCaptureStop: { [weak self] in self?.lastCaptureStop }
        )
        learning.start()
    }

    // MARK: Channels

    func addChannel() {
        let channel = document.addChannel()
        selection = .channel(channel.id)
    }

    // MARK: Groups

    /// The folder or channel whose name the sidebar is editing inline.
    var itemBeingRenamed: SidebarItem?

    /// Starts editing a folder's or channel's name in the sidebar.
    func beginRenaming(_ item: SidebarItem) {
        switch item {
        case .channel, .group:
            selection = item
            itemBeingRenamed = item
        default:
            break  // Combined, Matrix, Activity have fixed names
        }
    }

    /// Makes "New Group", selects it and starts renaming it, as Finder does.
    func addGroup() {
        let group = document.addGroup()
        selection = .group(group.id)
        itemBeingRenamed = .group(group.id)
    }

    /// No confirmation: the group's channels are kept, just ungrouped.
    func deleteGroup(_ id: ChannelGroup.ID) {
        if selection == .group(id) { selection = .combined }
        if itemBeingRenamed == .group(id) { itemBeingRenamed = nil }
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
        if itemBeingRenamed == .channel(id) { itemBeingRenamed = nil }
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
        learning.captureStarted()
        guard await hasMicrophoneAccess() else {
            lastMessage = "Wilco can't use audio input. Allow it in System Settings › Privacy & Security › Microphone, then start capture again."
            return
        }
        // A second press while the access check was pending.
        guard !isCapturing else { return }
        // The microphone prompt may have let labelling start meanwhile; stop it,
        // with no await before capture state is set.
        learning.captureStarted()
        let start = Date()
        sessionStart = start
        // One zone for the file name and every line, so the session reads
        // in local time wherever it's opened later.
        let zone = TimeZone.current
        let transcriptURL = DataLocations.transcripts.appending(path: TranscriptFile.fileName(for: start, timeZone: zone))
        writer = TranscriptWriter(url: transcriptURL, show: document, timeZone: zone)
        let recorder = DiagnosticsRecorder(
            writer: DiagnosticsWriter(url: DiagnosticsFile.url(forTranscript: transcriptURL)),
            sessionStart: start, classifier: soundClassifier)
        diagnostics = recorder
        transcription.diagnostics = recorder.tap
        if UserDefaults.standard.bool(forKey: "learning.keepClips") {
            let keeper = ClipKeeper(folder: ClipsFolder.url(forTranscript: transcriptURL))
            clipKeeper = keeper
            transcription.clips = keeper.tap
        }
        reportedWriteFailure = false
        evaluator.reset()
        pendingLines = PendingLines()
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
        lastCaptureStop = Date()
        learning.captureStopped()
        capture.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        meters = [:]
        let transcription = transcription
        // This session's recorder, so one started at once gets its own.
        let recorder = diagnostics
        diagnostics = nil
        transcription.diagnostics = nil
        let keeper = clipKeeper
        clipKeeper = nil
        transcription.clips = nil
        // Likewise the writer: a restart during the recorder's wait must not skip this one's end copy.
        let finishing = writer
        Task {
            await transcription.stopAll()
            await keeper?.finish()
            if sessionStart == nil, let finishing {
                finishing.finish(show: document)
                if writer === finishing { writer = nil }
            }
            await recorder?.finish()
        }
    }

    /// A model finished installing: channels that failed or run without
    /// vocabulary boosting for want of it start again; the rest carry on.
    private func modelsInstalled() {
        guard let sessionStart else { return }
        transcription.modelsInstalled(statuses: transcriberStatus, capture: capture, sessionStart: sessionStart)
    }

    func clearTranscript(channelID: ChannelConfig.ID? = nil) {
        timeline.clear(channelID: channelID)
    }

    /// Says in the Activity log when a regular expression was stopped at
    /// the time limit, since it won't match again until Wilco restarts.
    private func reportStalledPatterns(in show: ShowDocument) {
        for pattern in KeywordMatcher.takeNewlyStalled() {
            let rule = show.rules.first { $0.matchMode == .regularExpression && $0.phrases.contains(pattern) }
            log(ActivityEntry(
                kind: .error, ruleName: rule?.name ?? "Highlight",
                detail: "The pattern “\(pattern)” took too long to check and is switched off until Wilco restarts. Simplify it in Settings › Automation."
            ))
        }
    }

    private func apply(_ update: TranscriptionController.Update) {
        switch update {
        case .event(let event):
            let show = document
            let now = Date()
            defer { reportStalledPatterns(in: show) }
            switch event.stage {
            case .complete:
                // One stage: rules, display and file all get the line now.
                var firings: [AutomationEvaluator.Firing] = []
                guard let segment = timeline.apply(event, at: now, annotate: { segment in
                    segment.highlights = AutomationEvaluator.highlights(for: segment.text, channelID: segment.channelID, in: show)
                    firings = evaluator.evaluate(segment, in: show, at: now)
                    segment.matchedKeywords = AutomationEvaluator.matchedKeywords(firings)
                }) else { return }
                write(segment)
                perform(firings, text: segment.text, channelID: segment.channelID, date: segment.timestamp,
                        offset: segment.sessionOffset, show: show)
            case .recognized:
                // Cues come first: rules fire on the recognised line without
                // waiting for voice analysis. It shows as in progress and is
                // stored when its annotated pieces arrive.
                timeline.apply(event, at: now)
                let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard event.isFinal, !text.isEmpty else { return }
                let firings = evaluator.evaluate(text: text, channelID: event.channelID, in: show, at: now)
                pendingLines.recognized(
                    event.lineID, text: text, keywords: AutomationEvaluator.matchedKeywords(firings), at: now
                )
                perform(firings, text: text, channelID: event.channelID, date: now, offset: event.sessionOffset, show: show)
            case .annotated:
                // Rules already ran on the recognised line; each piece gets
                // its own highlights and the keywords it said.
                guard let segment = timeline.apply(event, at: now, annotate: { segment in
                    segment.highlights = AutomationEvaluator.highlights(for: segment.text, channelID: segment.channelID, in: show)
                    segment.matchedKeywords = pendingLines.keywords(forPiece: segment.text, of: event.lineID, at: now)
                }) else { return }
                write(segment)
            }
        case .status(let channelID, let status):
            transcriberStatus[channelID] = status
        }
    }

    /// Appends a stored line (`.complete` or `.annotated`, never
    /// `.recognized`) to the session file.
    private func write(_ segment: TranscriptSegment) {
        do {
            try writer?.append(segment)
        } catch where !reportedWriteFailure {
            reportedWriteFailure = true
            lastMessage = "Could not write the transcript file: \(error.localizedDescription). Lines are still shown on screen."
        } catch {}
    }

    private func perform(
        _ firings: [AutomationEvaluator.Firing], text: String, channelID: UUID, date: Date, offset: Double,
        show: ShowDocument
    ) {
        guard !firings.isEmpty else { return }
        let channelName = show.channel(id: channelID)?.name ?? "Unknown channel"
        for firing in firings {
            // Rules run before voice analysis, so `{voice}` is always empty here.
            let context = TemplateContext(
                text: text, channel: channelName, keyword: firing.matched.first ?? "",
                date: date, offset: offset, voice: "", rule: firing.rule.name
            )
            performer.perform(firing.rule, context: context, show: show, channelID: channelID)
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
            offset: sessionStart.map { Date().timeIntervalSince($0) } ?? 0,
            rule: rule.name
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
