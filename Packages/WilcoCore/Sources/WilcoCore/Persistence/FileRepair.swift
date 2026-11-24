import Foundation

/// Repairs applied to everything read from disk, at the point it is read.
///
/// A file can be corrupt, hand-edited or written by someone else, and Swift
/// traps on an out-of-range number conversion or array index. Code past
/// this boundary may therefore assume what these repairs guarantee: numbers
/// are finite and within the limits below, and IDs are unique. A new file
/// format, or a new numeric field in an old one, gets its repair here and a
/// case in `HostileInputTests`.
public enum FileLimits {
    /// Longest session a file may describe. Offsets past it are pulled back.
    public static let maximumSessionSeconds: Double = 31 * 24 * 60 * 60
    public static let maximumSessionMinutes = Int(maximumSessionSeconds / 60)
    /// Largest show file import will read. Real shows are a few kilobytes.
    public static let maximumShowFileBytes = 20 * 1024 * 1024
    /// Longest rule cooldown, in seconds.
    public static let maximumCooldown: Double = 24 * 60 * 60
    /// Largest count a diagnostics row may carry (frames, utterances, cuts).
    public static let maximumCount = 1_000_000_000
}

extension Double {
    /// The value held within `range`; the lower bound when it isn't a number.
    func repaired(in range: ClosedRange<Double>) -> Double {
        isNaN ? range.lowerBound : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    func repaired(in range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// A whole number from any `Double` without trapping: fractions are
    /// dropped, out-of-range values are held at the nearest `Int`, and
    /// not-a-number becomes 0.
    public init(safely value: Double) {
        if value.isNaN { self = 0 }
        else if value >= 0x1p63 { self = .max }
        else if value <= -0x1p63 { self = .min }
        else { self = Int(value) }
    }
}

extension Array where Element: Identifiable {
    /// The first element with each ID. Views and lookups key on IDs, and a
    /// dictionary built from duplicate keys traps.
    func uniqueByID() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension TranscriptSegment {
    public var repaired: TranscriptSegment {
        var copy = self
        copy.sessionOffset = sessionOffset.repaired(in: 0...FileLimits.maximumSessionSeconds)
        copy.confidence = confidence.map { $0.repaired(in: 0...1) }
        copy.exchange = exchange.map { $0.repaired(in: 0...FileLimits.maximumCount) }
        return copy
    }
}

extension ChannelMinute {
    public var repaired: ChannelMinute {
        var copy = self
        copy.minute = minute.repaired(in: 0...FileLimits.maximumSessionMinutes)
        copy.audio = audio.repaired(in: 0...60)
        copy.sound = sound.repaired(in: 0...60)
        copy.clipped = clipped.repaired(in: 0...FileLimits.maximumCount)
        copy.dropped = dropped.repaired(in: 0...FileLimits.maximumCount)
        copy.droppedSeconds = droppedSeconds.repaired(in: 0...FileLimits.maximumSessionSeconds)
        copy.utterances = utterances.map { $0.repaired(in: 0...FileLimits.maximumCount) }
        copy.speech = speech.map { $0.repaired(in: 0...60) }
        copy.cuts = cuts.map { $0.repaired(in: 0...FileLimits.maximumCount) }
        copy.recognize = recognize.map { $0.repaired(in: 0...FileLimits.maximumSessionSeconds) }
        return copy
    }
}

extension VoiceChangeSettings {
    var repaired: VoiceChangeSettings {
        VoiceChangeSettings(
            threshold: threshold.repaired(in: 0...1),
            exchangeGap: exchangeGap.repaired(in: 0...3_600),
            shortLine: shortLine.repaired(in: 0...60)
        )
    }
}

extension ShowDocument {
    /// Run at the end of decoding, so every show in memory has unique IDs
    /// and in-range numbers however its file was written.
    mutating func repair() {
        channels = channels.uniqueByID()
        groups = groups.uniqueByID()
        rules = rules.uniqueByID()
        highlights = highlights.uniqueByID()
        destinations = destinations.uniqueByID()
        for index in rules.indices {
            rules[index].cooldown = rules[index].cooldown.repaired(in: 0...FileLimits.maximumCooldown)
        }
        voiceChanges = voiceChanges.repaired
    }
}
