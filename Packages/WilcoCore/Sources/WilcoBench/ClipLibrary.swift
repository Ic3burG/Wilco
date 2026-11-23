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

    /// Unbroken talking of about 15 s (13–17 s in the usual voices), as someone explains a problem or talks a
    /// crew through a sequence on comms. Few full stops, so the voices don't
    /// pause long enough to end the line. Plain words and no digits, so a
    /// lost word is a lost word and not a spelling difference.
    public static let passages = [
        "The long form seems to do the live transcription much faster, and it builds better sentences, "
            + "while the other two engines keep dropping whole stretches of what I am saying whenever I talk for a while "
            + "without stopping to take a proper breath between one thought and the next one.",
        "So what happened in the first half was that the truck came on a little late because the wagon brake "
            + "was still down, and by the time we got it released the lighting had already moved on to the next look, "
            + "which is why the whole shift looked messy from the front and why I want to run it again before we break.",
        "When we get to the end of the song I am going to call the lights first and then the fly piece, "
            + "and I need everyone on the deck to wait until the cloth is all the way in and you hear me say clear "
            + "before anybody walks under it, because we came very close to someone standing in the wrong place last night.",
        "I have been listening to the vocal on the left side of the room and it sounds thin to me, "
            + "as if something is missing in the low end, so could somebody walk out to the middle of the house "
            + "and tell me whether it is the speaker itself or just where I happen to be sitting at the back.",
        "Before we open the house I want to go through the whole change one more time with the crew, "
            + "starting from the moment the table comes off and going right through until the chairs are set "
            + "and the door is closed, so that everybody knows exactly where they are meant to be standing "
            + "and nobody is left guessing in the dark.",
        "The reason the picture dropped out for a moment is that the cable running along the back wall "
            + "got kicked when the band were loading in their cases, and although we have pushed it back in "
            + "and taped it down I would still like someone to stay near it during the show in case it happens again.",
        "Thank you everyone for a really good afternoon, we got through a lot more than I expected, "
            + "and after the break we are going to pick up from the top of the second half and keep going "
            + "without stopping unless something is unsafe, so please be back in your places and ready to go "
            + "a few minutes before the hour.",
    ]

    /// The cue words `phrases` use, as a show would list them for boosting.
    public static let vocabulary = [
        "Standby", "Lighting", "Sound", "Video", "Automation", "Pyro", "Places",
        "Deck", "Rail", "Spot", "Front of house", "Follow spots", "Wardrobe",
        "Props", "Curtain", "Overture", "Interval", "Blackout",
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

    /// Every text (the short calls, unless told otherwise) in up to `voiceLimit` voices, rendered by `say` once and
    /// cached. Synthetic speech is clean, so treat it as a best case: real
    /// comms (hiss, clipping, talking over) will score worse.
    public static func synthesized(
        _ texts: [String] = phrases, sampleRate: Double, cacheDirectory: URL, voiceLimit: Int = 4
    ) throws -> (clips: [BenchClip], voices: [String]) {
        let voices = pick(preferredVoices, from: parseVoices(try run("/usr/bin/say", ["-v", "?"])), limit: voiceLimit)
        guard !voices.isEmpty else {
            throw BenchError("None of the benchmark voices are installed: \(preferredVoices.map(\.label))")
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var clips: [BenchClip] = []
        for (number, voice) in voices.enumerated() {
            for phrase in texts {
                let key = SHA256.hash(data: Data("\(voice.label)|\(phrase)|\(Int(sampleRate))".utf8))
                    .prefix(8).map { String(format: "%02x", $0) }.joined()
                let file = cacheDirectory.appending(path: "\(key).wav")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try say(phrase, voice: voice.name, to: file, sampleRate: sampleRate)
                }
                clips.append(BenchClip(text: phrase, samples: try readMono(file, sampleRate: sampleRate), voice: number))
            }
        }
        return (clips, voices.map(\.label))
    }

    /// Recordings in `folder`, each `name.wav` (or .aif, .caf, .m4a, .mp3,
    /// .flac) with a `name.txt` holding what was said. One call per file.
    /// Lines of `name.txt` may start with a speaker mark ("A: "); the same
    /// letter in different files is the same person.
    public static func load(folder: URL, sampleRate: Double) throws -> [BenchClip] {
        let audio = Set(["wav", "aif", "aiff", "caf", "m4a", "mp3", "flac"])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let read = try files.map { file -> (text: String, speaker: String?, samples: [Float]) in
            let transcript = file.deletingPathExtension().appendingPathExtension("txt")
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
                throw BenchError("\(file.lastPathComponent) has no \(transcript.lastPathComponent) beside it")
            }
            do {
                let parsed = try Self.transcript(text)
                return (parsed.text, parsed.speaker, try readMono(file, sampleRate: sampleRate))
            } catch let error as BenchError {
                throw BenchError("\(transcript.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !read.isEmpty else { throw BenchError("No recordings in \(folder.path)") }
        let voices = voiceNumbers(for: read.map(\.speaker))
        return zip(read, voices).map { BenchClip(text: $0.text, samples: $0.samples, voice: $1) }
    }

    /// What a corpus transcript says, and who says it. Each line may start
    /// with a one-letter speaker mark ("A: "). A recording is one turn, so
    /// its marked lines must all name the same speaker.
    static func transcript(_ contents: String) throws -> (text: String, speaker: String?) {
        var speaker: String?
        var parts: [String] = []
        for raw in contents.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let mark = line.range(of: #"^[A-Z]:\s+"#, options: .regularExpression) {
                let letter = String(line[line.startIndex])
                if let speaker, speaker != letter {
                    throw BenchError("speakers \(speaker) and \(letter) in one recording; split it into one file per turn")
                }
                speaker = letter
                line = String(line[mark.upperBound...])
            }
            if !line.isEmpty { parts.append(line) }
        }
        return (parts.joined(separator: " "), speaker)
    }

    /// Speaker marks as voice numbers, in letter order. Unmarked recordings
    /// count as one more speaker of their own, numbered first.
    static func voiceNumbers(for speakers: [String?]) -> [Int] {
        let keys = Set(speakers.map { $0 ?? "" }).sorted()
        return speakers.map { keys.firstIndex(of: $0 ?? "")! }
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

    static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
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
