import SwiftUI
import WilcoCore
import WilcoTranscription

/// Whether to keep short audio clips of unclear lines, and how much space they use.
struct LearningSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.keepClipsKey) private var keepClips = false
    @AppStorage(SettingsPage.storageKey) private var selectedPage = SettingsPage.audio.rawValue

    @State private var size: Int64 = 0
    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    @State private var ultraSize: Int64?
    @State private var appleStatus: SpeechAssetStatus?
    @State private var whisperLargeSize: Int64?
    @State private var sortformerSize: Int64?

    private var installer: ModelInstaller { model.installer }

    var body: some View {
        Form {
            Section {
                Toggle("Keep audio clips to learn from shows", isOn: $keepClips)
                    .onChange(of: keepClips) { _, isOn in model.keepingClipsChanged(to: isOn) }
                SettingsFooter("Short clips of unclear lines and exchanges, saved beside each session.",
                               more: "They never leave this Mac. About 30–50 MB a show. Turned on during a capture, it keeps lines that start from then on; turned off, it stops at once and keeps what's saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Using", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                Button("Delete All Clips", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(model.isCapturing || size == 0)
                .help(model.isCapturing ? "Stop capture to delete clips" : "Delete every saved clip")
            }
            votersSection
            if let status = model.learning.status {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(status)
                    }
                } footer: {
                    Text("Runs in the background when nothing is capturing, and stops when capture starts.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshSize)
        .task(id: installer.generation) {
            // Re-check now and then: macOS can add or remove its speech
            // models, and clips are written while a capture runs.
            while !Task.isCancelled {
                await refreshVoters()
                await refreshSizeInBackground()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Delete all clips?", isPresented: $confirmingDelete) {
            Button("Delete All Clips", role: .destructive) {
                do { try ClipsFolder.deleteAll(in: DataLocations.transcripts) } catch { deleteFailed = true }
                refreshSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all clips? Labels made from them go too.")
        }
        .alert("Some clips couldn't be deleted", isPresented: $deleteFailed) {
            Button("OK") {}
        }
    }

    // MARK: Voters

    /// The models that transcribe kept clips after a show, so their texts can
    /// be compared. Two must agree before a clip counts. They are downloaded
    /// in Speech Models; this shows how many are ready.
    private var votersSection: some View {
        Section {
            LabeledContent("Voters installed", value: "\(installedVoters) of 3")
            LabeledContent("Voice grouping", value: sortformerSize != nil ? "Installed" : "Not installed")
            Button("Speech Models…") { selectedPage = SettingsPage.speechModels.rawValue }
                .help("Download or remove the models learning uses")
        } header: {
            Text("Voters")
        } footer: {
            SettingsFooter("Labelling needs at least two.", more: "A channel's own engine doesn't vote on its clips.")
        }
    }

    private var installedVoters: Int {
        [ultraSize != nil, appleStatus == .installed, whisperLargeSize != nil]
            .filter { $0 }.count
    }

    private func refreshVoters() async {
        let ultra = installer.parakeetUltraStore
        let whisper = installer.whisperStore
        let sortformer = installer.sortformer
        let sizes = await Task.detached {
            (ultra.sizeOnDisk(), whisper.sizeOnDisk(of: .large), sortformer.sizeOnDisk())
        }.value
        ultraSize = sizes.0
        whisperLargeSize = sizes.1
        sortformerSize = sizes.2
        // Clips are labelled with the English model.
        appleStatus = await SpeechAssets.status(engine: .longForm, localeIdentifier: "en-US")
    }

    private func refreshSize() {
        size = ClipsFolder.totalSize(in: DataLocations.transcripts)
    }

    /// The same, with the folder walk off the main thread: it runs every few
    /// seconds while the pane is open, captures included, and a season of
    /// clips is thousands of files.
    private func refreshSizeInBackground() async {
        let transcripts = DataLocations.transcripts
        size = await Task.detached(priority: .utility) { ClipsFolder.totalSize(in: transcripts) }.value
    }
}
