@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Where a run's speech comes from.
public enum ClipLibrary {
    /// Calls of the kind heard on a show's comms ring, written as a stage
    /// manager would say them. Numbers are spoken forms so the voices read
    /// them naturally; the normalizer accepts digits back.
    public static let phrases = [
        "Standby lighting cue forty two.",
        "Lighting cue forty two, go.",
        "Standby sound cue seven and fly cue three.",
        "Sound seven, fly three, go.",
        "House to half, please.",
        "Places please for the top of act two.",
        "Thank you, five minutes.",
        "Can I get a headset check from stage left?",
        "Stage left, loud and clear.",
        "Spot one, pick up the lead at centre.",
        "Deck, are we clear for the shift?",
        "Deck is clear.",
        "Hold please, we have a hold.",
        "We are going again from the top of the scene.",
        "Standby video cue twelve.",
        "Video twelve, go.",
        "Follow spots, standby for the blackout.",
        "Can someone check the radio mic on track four?",
        "Front of house, how are we looking for clearance?",
        "Front of house clear, you have the show.",
        "Rail, standby to fly in the drop.",
        "Automation cue eighteen, go.",
        "Pyro is armed and ready.",
        "Stop, stop, stop. Hold everything.",
        "Can I get a work light on stage right?",
        "Ten minutes, this is your ten minute call.",
        "Standby the band for the overture.",
        "Conductor is in the pit.",
        "Wardrobe to quick change, stage right.",
        "Props table, is the lantern preset?",
        "Fog machine on, please.",
        "Lighting cue one hundred five, go.",
        "Sound, can you bring the playback up a touch?",
        "Thanks everyone, that's the interval.",
        "Second half beginners to the stage, please.",
        "Standby for the curtain call.",
        "Curtain out.",
        "Spot two, you're late on that pick up.",
        "Copy that.",
        "Standing by.",
    ]

    /// A voice as `say -v ?` lists it.
    public struct SystemVoice: Equatable, Sendable {
        /// The name `say -v` takes, e.g. "Rishi (English (India))".
        public var name: String
        public var locale: String

        public init(name: String, locale: String) {
            self.name = name
            self.locale = locale
        }

        /// The name without macOS's qualifier: "Rishi". macOS lists the same
        /// voice as "Rishi" or "Rishi (English (India))" depending on its
        /// voice assets, so voices are chosen and cached by this and the locale.
        public var baseName: String {
            name.range(of: " (").map { String(name[..<$0.lowerBound]) } ?? name
        }

        var label: String { "\(baseName) \(locale)" }
    }

    /// System voices with different accents, used where installed, in this order.
    public static let preferredVoices: [SystemVoice] = [
        .init(name: "Samantha", locale: "en_US"), .init(name: "Daniel", locale: "en_GB"),
        .init(name: "Karen", locale: "en_AU"), .init(name: "Moira", locale: "en_IE"),
        .init(name: "Rishi", locale: "en_IN"), .init(name: "Tessa", locale: "en_ZA"),
        .init(name: "Eddy", locale: "en_GB"), .init(name: "Flo", locale: "en_US"),
        .init(name: "Reed", locale: "en_US"), .init(name: "Shelley", locale: "en_GB"),
    ]

    /// Every phrase in up to `voiceLimit` voices, rendered by `say` once and
    /// cached. Synthetic speech is clean, so treat it as a best case: real
    /// comms (hiss, clipping, talking over) will score worse.
    public static func synthesized(
        sampleRate: Double, cacheDirectory: URL, voiceLimit: Int = 4
    ) throws -> (clips: [BenchClip], voices: [String]) {
        let voices = pick(preferredVoices, from: parseVoices(try run("/usr/bin/say", ["-v", "?"])), limit: voiceLimit)
        guard !voices.isEmpty else {
            throw BenchError("None of the benchmark voices are installed: \(preferredVoices.map(\.label))")
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var clips: [BenchClip] = []
        for voice in voices {
            for phrase in phrases {
                let key = SHA256.hash(data: Data("\(voice.label)|\(phrase)|\(Int(sampleRate))".utf8))
                    .prefix(8).map { String(format: "%02x", $0) }.joined()
                let file = cacheDirectory.appending(path: "\(key).wav")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try say(phrase, voice: voice.name, to: file, sampleRate: sampleRate)
                }
                clips.append(BenchClip(text: phrase, samples: try readMono(file, sampleRate: sampleRate)))
            }
        }
        return (clips, voices.map(\.label))
    }

    /// Recordings in `folder`, each `name.wav` (or .aif, .caf, .m4a, .mp3,
    /// .flac) with a `name.txt` holding what was said. One call per file.
    public static func load(folder: URL, sampleRate: Double) throws -> [BenchClip] {
        let audio = Set(["wav", "aif", "aiff", "caf", "m4a", "mp3", "flac"])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let clips = try files.map { file -> BenchClip in
            let transcript = file.deletingPathExtension().appendingPathExtension("txt")
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
                throw BenchError("\(file.lastPathComponent) has no \(transcript.lastPathComponent) beside it")
            }
            return BenchClip(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                samples: try readMono(file, sampleRate: sampleRate)
            )
        }
        guard !clips.isEmpty else { throw BenchError("No recordings in \(folder.path)") }
        return clips
    }

    /// Lines look like "Samantha (English (US)) en_US    # Hello! …". The
    /// name can contain spaces and brackets, so it's cut before the locale.
    static func parseVoices(_ listing: String) -> [SystemVoice] {
        listing.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: #"\s+[a-z]{2,3}_[A-Za-z0-9]+\s+#"#, options: .regularExpression) else {
                return nil
            }
            let locale = line[range].trimmingCharacters(in: CharacterSet.whitespaces.union(["#"]))
            return SystemVoice(name: String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), locale: locale)
        }
    }

    /// The installed voice for each wanted one, by base name and locale.
    /// Standard voices win over "Enhanced" and "Premium" downloads, which
    /// not every Mac has.
    static func pick(_ wanted: [SystemVoice], from installed: [SystemVoice], limit: Int) -> [SystemVoice] {
        let standardFirst = installed.filter { !$0.name.contains("Enhanced") && !$0.name.contains("Premium") }
            + installed.filter { $0.name.contains("Enhanced") || $0.name.contains("Premium") }
        let found = wanted.compactMap { want in
            standardFirst.first { $0.baseName == want.baseName && $0.locale == want.locale }
        }
        return Array(found.prefix(limit))
    }

    private static func say(_ text: String, voice: String, to file: URL, sampleRate: Double) throws {
        _ = try run("/usr/bin/say", [
            "-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEF32@\(Int(sampleRate))", text,
        ])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BenchError("\(tool) \(arguments.prefix(2).joined(separator: " ")) failed (\(process.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The file's audio, mixed to mono and converted to `sampleRate`.
    static func readMono(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchError("Could not read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw BenchError("\(url.lastPathComponent) isn't float audio") }
        let frames = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(channelCount) }
        }
        guard format.sampleRate != sampleRate else { return mono }
        return try resample(mono, from: format.sampleRate, to: sampleRate)
    }

    private static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: input, to: output),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuffer = AVAudioPCMBuffer(
                  pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(samples.count) * target / source) + 1_024
              )
        else { throw BenchError("Could not convert \(source) Hz audio to \(target) Hz") }
        inBuffer.frameLength = inBuffer.frameCapacity
        samples.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}

public struct BenchError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
