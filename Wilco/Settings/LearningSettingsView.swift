import SwiftUI
import WilcoCore
import WilcoTranscription

/// Whether to keep short audio clips of unclear lines, and how much space they use.
struct LearningSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.keepClipsKey) private var keepClips = false

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
                Text("Short clips of unclear lines and exchanges, saved beside each session. They never leave this Mac. About 30–50 MB a show. Turned on during a capture, it keeps lines that start from then on; turned off, it stops at once and keeps what's saved.")
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
    /// be compared. Two must agree before a clip counts.
    private var votersSection: some View {
        Section {
            LabeledContent {
                downloadStatus(for: .parakeetUltra, size: ultraSize)
            } label: {
                Text("Parakeet Ultra")
                if let ultraSize { Text(ultraSize.formatted(.byteCount(style: .file))) }
            }
            LabeledContent("Apple Long-form") { appleLongFormStatus }
            LabeledContent {
                downloadStatus(for: .whisper(.large), size: whisperLargeSize)
            } label: {
                Text("Whisper large-v3")
                Text(whisperLargeSize.map { $0.formatted(.byteCount(style: .file)) } ?? "(optional, about 3 GB)")
            }
            LabeledContent {
                downloadStatus(for: .sortformer, size: sortformerSize)
            } label: {
                Text("Voice grouping")
                Text(sortformerSize.map { $0.formatted(.byteCount(style: .file)) } ?? "Sortformer, about 240 MB")
                Text("Groups voices after a show. The voice-change model (Languages) is needed too.")
            }
        } header: {
            Text("Voters")
        } footer: {
            Text("Labelling needs at least two. A channel's own engine doesn't vote on its clips.")
        }
    }

    @ViewBuilder
    private var appleLongFormStatus: some View {
        switch appleStatus {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notInstalled:
            Text("Install in Languages").foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading…").foregroundStyle(.secondary)
        case .unavailable:
            Text("Needs macOS 26").foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func downloadStatus(for item: ModelInstaller.Item, size: Int64?) -> some View {
        if let fraction = installer.progress[item] {
            HStack {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        } else {
            HStack {
                if let error = installer.errors[item] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
                }
                if size != nil {
                    Button("Remove") { installer.remove(item) }
                } else {
                    Button("Download") { installer.install(item) }
                }
            }
        }
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
