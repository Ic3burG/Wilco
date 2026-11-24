import Foundation

/// The classifier's confidence that a clip is speech, music or singing.
public struct SoundShares: Codable, Equatable, Sendable {
    public var speech: Double
    public var music: Double
    public var singing: Double

    public init(speech: Double, music: Double, singing: Double) {
        self.speech = speech
        self.music = music
        self.singing = singing
    }
}

/// One channel's measurements for one minute of a session: one line of the
/// `.diagnostics` file. Decoding is lenient so later versions can add fields.
public struct ChannelMinute: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var channel: UUID
    /// Minute of the session: `floor(offset / 60)`.
    public var minute: Int
    /// Seconds of audio the engine read this minute.
    public var audio: Double
    /// Seconds of 20 ms frames above the sound floor.
    public var sound: Double
    public var rms: Double?
    public var peak: Double?
    public var floor: Double?
    public var clipped: Int
    /// Frames the ring dropped because the engine fell behind.
    public var dropped: Int
    public var droppedSeconds: Double
    public var utterances: Int?
    public var speech: Double?
    public var cuts: Int?
    public var recognize: Double?
    /// True when the transcriber started, stopped or restarted this minute.
    /// Written only when true.
    public var partial: Bool?
    public var classified: SoundShares?

    public init(
        channel: UUID, minute: Int, audio: Double, sound: Double,
        rms: Double? = nil, peak: Double? = nil, floor: Double? = nil,
        clipped: Int = 0, dropped: Int = 0, droppedSeconds: Double = 0,
        utterances: Int? = nil, speech: Double? = nil, cuts: Int? = nil, recognize: Double? = nil,
        partial: Bool? = nil, classified: SoundShares? = nil
    ) {
        self.channel = channel
        self.minute = minute
        self.audio = audio
        self.sound = sound
        self.rms = rms
        self.peak = peak
        self.floor = floor
        self.clipped = clipped
        self.dropped = dropped
        self.droppedSeconds = droppedSeconds
        self.utterances = utterances
        self.speech = speech
        self.cuts = cuts
        self.recognize = recognize
        self.partial = partial
        self.classified = classified
    }

    private enum CodingKeys: String, CodingKey {
        case v, channel, minute, audio, sound, rms, peak, floor, clipped, dropped, droppedSeconds
        case utterances, speech, cuts, recognize, partial, classified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        channel = try c.decode(UUID.self, forKey: .channel)
        minute = try c.decode(Int.self, forKey: .minute)
        audio = try c.decode(Double.self, forKey: .audio)
        sound = try c.decode(Double.self, forKey: .sound)
        rms = try c.decodeIfPresent(Double.self, forKey: .rms)
        peak = try c.decodeIfPresent(Double.self, forKey: .peak)
        floor = try c.decodeIfPresent(Double.self, forKey: .floor)
        clipped = try c.decodeIfPresent(Int.self, forKey: .clipped) ?? 0
        dropped = try c.decodeIfPresent(Int.self, forKey: .dropped) ?? 0
        droppedSeconds = try c.decodeIfPresent(Double.self, forKey: .droppedSeconds) ?? 0
        utterances = try c.decodeIfPresent(Int.self, forKey: .utterances)
        speech = try c.decodeIfPresent(Double.self, forKey: .speech)
        cuts = try c.decodeIfPresent(Int.self, forKey: .cuts)
        recognize = try c.decodeIfPresent(Double.self, forKey: .recognize)
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial)
        classified = try c.decodeIfPresent(SoundShares.self, forKey: .classified)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(channel, forKey: .channel)
        try c.encode(minute, forKey: .minute)
        try c.encode(audio, forKey: .audio)
        try c.encode(sound, forKey: .sound)
        try c.encodeIfPresent(rms, forKey: .rms)
        try c.encodeIfPresent(peak, forKey: .peak)
        try c.encodeIfPresent(floor, forKey: .floor)
        try c.encode(clipped, forKey: .clipped)
        try c.encode(dropped, forKey: .dropped)
        try c.encode(droppedSeconds, forKey: .droppedSeconds)
        try c.encodeIfPresent(utterances, forKey: .utterances)
        try c.encodeIfPresent(speech, forKey: .speech)
        try c.encodeIfPresent(cuts, forKey: .cuts)
        try c.encodeIfPresent(recognize, forKey: .recognize)
        if partial == true { try c.encode(true, forKey: .partial) }
        try c.encodeIfPresent(classified, forKey: .classified)
    }

    /// Folds a second row for the same channel and minute into this one (a
    /// transcriber that restarted mid-minute). Counts add, the peak is the
    /// higher, the floor the lower. The RMS of the row with more sound wins:
    /// a whole-minute RMS can't be rebuilt from two RMS values without their
    /// sums, and this is close enough.
    public mutating func merge(_ other: ChannelMinute) {
        if other.sound > sound { rms = other.rms ?? rms } else { rms = rms ?? other.rms }
        audio += other.audio
        sound += other.sound
        clipped += other.clipped
        dropped += other.dropped
        droppedSeconds += other.droppedSeconds
        utterances = Self.sum(utterances, other.utterances)
        speech = Self.sum(speech, other.speech)
        cuts = Self.sum(cuts, other.cuts)
        recognize = Self.sum(recognize, other.recognize)
        peak = [peak, other.peak].compactMap { $0 }.max()
        floor = [floor, other.floor].compactMap { $0 }.min()
        partial = true
        classified = classified ?? other.classified
    }

    private static func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): a + b
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}

/// The per-minute measurements of a session, kept beside its transcript as
/// `Session yyyy-MM-dd HHmm-ss.diagnostics`. The extension is deliberately
/// not `.jsonl`: every `.jsonl` in the transcripts folder is a session.
public enum DiagnosticsFile {
    public static let fileExtension = "diagnostics"

    public static func url(forTranscript transcript: URL) -> URL {
        transcript.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// One line of the file, newline included.
    public static func line(for row: ChannelMinute) throws -> Data {
        var data = try WilcoJSON.encoder().encode(row)
        data.append(0x0A)
        return data
    }

    /// Decodes every readable line. A torn final line, left by a crash
    /// mid-write, and any other unreadable line are skipped.
    public static func rows(in data: Data) -> [ChannelMinute] {
        let decoder = WilcoJSON.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ChannelMinute.self, from: $0).repaired }
    }
}

/// Appends rows to a session's `.diagnostics` file as minutes close. The file
/// and its folder are created on the first row, so a session in which nothing
/// was captured leaves no file.
public final class DiagnosticsWriter {
    public let url: URL
    private var handle: FileHandle?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    public func append(_ row: ChannelMinute) throws {
        try fileHandle().write(contentsOf: DiagnosticsFile.line(for: row))
    }

    private func fileHandle() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }
}
