import SwiftUI
import WilcoCore

/// Whether to keep short audio clips of unclear lines, and how much space they use.
struct LearningSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("learning.keepClips") private var keepClips = false

    @State private var size: Int64 = 0
    @State private var confirmingDelete = false
    @State private var deleteFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep audio clips to learn from shows", isOn: $keepClips)
                Text("Short clips of unclear lines and exchanges, saved beside each session. They never leave this Mac. About 30–50 MB a show. Takes effect at the next capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Using", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                Button("Delete All Clips", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(model.isCapturing || size == 0)
                .help(model.isCapturing ? "Stop capture to delete clips" : "Delete every saved clip")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshSize)
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

    private func refreshSize() {
        size = ClipsFolder.totalSize(in: DataLocations.transcripts)
    }
}
