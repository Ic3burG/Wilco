import AppKit
import SwiftUI
import WilcoCore

/// Settings › General: how Wilco behaves on this Mac. Nothing here is saved
/// in a show, so a show from someone else can't change it.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(GeneralPreferences.keepsDisplayAwakeKey)
    private var keepsDisplayAwake = GeneralPreferences.keepsDisplayAwakeDefault
    @AppStorage(GeneralPreferences.startsCaptureOnLaunchKey)
    private var startsCaptureOnLaunch = GeneralPreferences.startsCaptureOnLaunchDefault
    @AppStorage(GeneralPreferences.asksToQuitWhileCapturingKey)
    private var asksToQuitWhileCapturing = GeneralPreferences.asksToQuitWhileCapturingDefault
    @AppStorage(AppModel.asksToSaveOnQuitKey) private var asksToSaveOnQuit = true
    @AppStorage(SessionRetention.storageKey) private var keepForRaw = SessionRetention.Period.never.rawValue
    @State private var loginItem = LoginItem()
    @State private var usage: SessionRetention.Usage?
    @State private var expiredCount = 0
    @State private var dismissedCount = ReportModel.dismissedCount

    private var keepFor: Binding<SessionRetention.Period> {
        Binding(
            get: { SessionRetention.Period.restored(from: keepForRaw) },
            set: { keepForRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            captureSection
            openingSection
            quittingSection
            transcriptsSection
            reviewSection
        }
        .formStyle(.grouped)
        .onAppear {
            loginItem.refresh()
            dismissedCount = ReportModel.dismissedCount
        }
    }

    // MARK: Sections

    private var captureSection: some View {
        Section {
            Toggle("Keep the display awake while capturing", isOn: $keepsDisplayAwake)
                .onChange(of: keepsDisplayAwake) { model.keepingDisplayAwakeChanged() }
        } header: {
            Text("Capture")
        } footer: {
            SettingsFooter(
                "The Mac never goes to sleep by itself while capturing.",
                more: "From Start to Stop, idle sleep and App Nap are held off so capture can't stall unnoticed. Closing the lid, the power button or Sleep in the Apple menu still put the Mac to sleep."
            )
        }
    }

    private var openingSection: some View {
        Section {
            Toggle("Open Wilco at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
            if loginItem.needsApproval {
                LabeledContent("macOS needs you to allow Wilco in Login Items.") {
                    Button("Open Login Items…", action: loginItem.openLoginItemsSettings)
                }
                .foregroundStyle(.orange)
            }
            if let problem = loginItem.problem {
                Text(problem).foregroundStyle(.orange)
            }
            Toggle("Start capture when Wilco opens", isOn: $startsCaptureOnLaunch)
        } header: {
            Text("Opening")
        } footer: {
            SettingsFooter(
                "For a Mac kept for the show: after a restart or power cut it comes back listening.",
                more: "Capture starts as if Start had been pressed, so rules can fire straight away. The Activity log notes that it started by itself. Only this Mac's setting does this; a show file can't turn it on."
            )
        }
    }

    private var quittingSection: some View {
        Section {
            Toggle("Ask before quitting while capturing", isOn: $asksToQuitWhileCapturing)
            Toggle("Ask to save configuration changes when quitting", isOn: $asksToSaveOnQuit)
        } header: {
            Text("Quitting")
        } footer: {
            SettingsFooter("Quit is ⌥⌘Q.", more: "The show on screen is always kept and reopens as you left it; saving writes your changes into the loaded configuration too, and is only asked when the title says Edited or Not Saved. Quitting while capturing ends the session, so Wilco checks first.")
        }
    }

    private var transcriptsSection: some View {
        Section {
            Picker("Keep sessions", selection: keepFor) {
                ForEach(SessionRetention.Period.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Transcripts folder") {
                HStack {
                    Text(usageText).foregroundStyle(.secondary).monospacedDigit()
                    Button("Show in Finder", action: showTranscriptsFolder)
                }
            }
        } header: {
            Text("Transcripts")
        } footer: {
            SettingsFooter(retentionText, more: "A session's transcript, the show copy it was recorded with, its diagnostics and its clips go together. Nothing else in the folder is touched. Old sessions are checked each time Wilco opens, never during a show.")
        }
        .task(id: keepForRaw) { await measureTranscripts() }
    }

    private var reviewSection: some View {
        Section {
            LabeledContent("Dismissed suggestions") {
                HStack {
                    Text(dismissedCount == 0 ? "None" : "\(dismissedCount) hidden").foregroundStyle(.secondary)
                    Button("Show All Again") {
                        ReportModel.resetDismissed()
                        dismissedCount = ReportModel.dismissedCount
                    }
                    .disabled(dismissedCount == 0)
                }
            }
        } header: {
            Text("Review")
        } footer: {
            SettingsFooter("Brings back the findings you dismissed in Review, for every show.")
        }
    }

    // MARK: Transcripts

    private var usageText: String {
        guard let usage else { return "…" }
        guard usage.sessions > 0 else { return "No sessions yet" }
        let noun = usage.sessions == 1 ? "session" : "sessions"
        return "\(usage.sessions) \(noun), \(usage.bytes.formatted(.byteCount(style: .file)))"
    }

    private var retentionText: String {
        let period = keepFor.wrappedValue
        guard period != .never else { return "Sessions are kept until you delete them." }
        switch expiredCount {
        case 0: return "Sessions older than \(period.title.lowercased()) go to the Trash when Wilco opens."
        case 1: return "1 session is older than \(period.title.lowercased()) and goes to the Trash next time Wilco opens."
        default: return "\(expiredCount) sessions are older than \(period.title.lowercased()) and go to the Trash next time Wilco opens."
        }
    }

    /// Off the main thread: a folder of clips can hold thousands of files.
    private func measureTranscripts() async {
        let folder = DataLocations.transcripts
        let period = keepFor.wrappedValue
        let (usage, expired) = await Task.detached(priority: .utility) {
            (SessionRetention.usage(in: folder), SessionRetention.expired(in: folder, keepFor: period).count)
        }.value
        self.usage = usage
        expiredCount = expired
    }

    private func showTranscriptsFolder() {
        let folder = DataLocations.transcripts
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
