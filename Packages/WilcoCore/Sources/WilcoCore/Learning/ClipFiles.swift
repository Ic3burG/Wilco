import Foundation

public enum ClipKind: String, Codable, Sendable { case unclear, exchange }

/// One kept clip: a stretch of one channel's audio, saved beside the session.
public struct ClipRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var channel: UUID
    public var kind: ClipKind
    public var sessionOffset: Double
    public var duration: Double
    public var confidence: Double?
    /// `SpeechEngine` raw value.
    public var engine: String
    /// `WhisperModel` raw value, Whisper channels only.
    public var whisperModel: String?
    /// Shared by an exchange's clips, numbered from 1 per session.
    public var exchange: Int?

    public init(
        id: UUID = UUID(), channel: UUID, kind: ClipKind, sessionOffset: Double, duration: Double,
        confidence: Double? = nil, engine: String, whisperModel: String? = nil, exchange: Int? = nil
    ) {
        self.id = id
        self.channel = channel
        self.kind = kind
        self.sessionOffset = sessionOffset
        self.duration = duration
        self.confidence = confidence
        self.engine = engine
        self.whisperModel = whisperModel
        self.exchange = exchange
    }
}

public struct ClipManifest: Codable, Equatable, Sendable {
    public var version = 1
    public var clips: [ClipRecord] = []
    /// Clips not kept because a cap or the queue limit was reached.
    public var dropped = 0

    public init(clips: [ClipRecord] = [], dropped: Int = 0) {
        self.clips = clips
        self.dropped = dropped
    }
}

public enum WordsVerdict: String, Codable, Sendable { case agreed, disputed, checked, notEnoughVoters }
public enum VoiceVerdict: String, Codable, Sendable { case agreed, disputed }

public struct ClipLabel: Codable, Equatable, Sendable {
    public var clip: UUID
    public var words: WordsVerdict
    public var text: String?
    public var candidates: [String: String]
    public var voice: VoiceVerdict?
    public var speaker: Int?
    /// Filled by a later stage; this stage only decodes and keeps it.
    public var checked: String?

    /// The words to score against: the checked text, else the voters' text
    /// when they agreed.
    public var answer: String? { checked ?? (words == .agreed ? text : nil) }

    public init(
        clip: UUID, words: WordsVerdict, text: String? = nil, candidates: [String: String] = [:],
        voice: VoiceVerdict? = nil, speaker: Int? = nil, checked: String? = nil
    ) {
        self.clip = clip
        self.words = words
        self.text = text
        self.candidates = candidates
        self.voice = voice
        self.speaker = speaker
        self.checked = checked
    }
}

public struct ClipLabels: Codable, Equatable, Sendable {
    public var version = 1
    public var voters: [String: String] = [:]
    public var clips: [ClipLabel] = []
    public var finished = false

    public init(voters: [String: String] = [:], clips: [ClipLabel] = [], finished: Bool = false) {
        self.voters = voters
        self.clips = clips
        self.finished = finished
    }
}

/// A session's kept clips: `Session yyyy-MM-dd HHmm-ss.clips`, a folder beside
/// the transcript holding `clips.json`, `labels.json` and one WAV per clip.
/// The extension is not `.jsonl`, so the folder is never listed as a session.
public enum ClipsFolder {
    public static let fileExtension = "clips"
    static let manifestName = "clips.json"
    static let labelsName = "labels.json"

    public static func url(forTranscript transcript: URL) -> URL {
        transcript.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    public static func audioURL(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id.uuidString).wav")
    }

    public static func loadManifest(in folder: URL) -> ClipManifest? {
        load(ClipManifest.self, named: manifestName, in: folder)
    }

    public static func loadLabels(in folder: URL) -> ClipLabels? {
        load(ClipLabels.self, named: labelsName, in: folder)
    }

    public static func save(_ manifest: ClipManifest, in folder: URL) throws {
        try write(manifest, named: manifestName, in: folder)
    }

    public static func save(_ labels: ClipLabels, in folder: URL) throws {
        try write(labels, named: labelsName, in: folder)
    }

    /// Bytes used by every `.clips` folder in the transcripts folder.
    public static func totalSize(in transcripts: URL) -> Int64 {
        var total: Int64 = 0
        for folder in clipsFolders(in: transcripts) {
            guard let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// Removes every `.clips` folder; transcripts and diagnostics stay.
    public static func deleteAll(in transcripts: URL) throws {
        for folder in clipsFolders(in: transcripts) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Transcripts whose `.clips` folder has a manifest with clips and no
    /// labels finished with exactly `voters`, oldest first by file name.
    /// Folders with no `.jsonl` are skipped.
    public static func needingLabels(in transcripts: URL, voters: [String: String]) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .filter { transcript in
                let folder = url(forTranscript: transcript)
                guard let manifest = loadManifest(in: folder), !manifest.clips.isEmpty else { return false }
                if let labels = loadLabels(in: folder), labels.finished, labels.voters == voters { return false }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func clipsFolders(in transcripts: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == fileExtension }
    }

    private static func load<T: Decodable>(_ type: T.Type, named name: String, in folder: URL) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? WilcoJSON.decoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, named name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = WilcoJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
