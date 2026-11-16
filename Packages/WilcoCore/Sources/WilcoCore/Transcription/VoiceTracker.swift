import Foundation

/// A speaker embedding for a short stretch of audio. Lives in memory only:
/// never written to disk, logs or exports.
public struct Voiceprint: Sendable {
    /// L2-normalised embedding.
    public var vector: [Float]
    /// Session offsets in seconds.
    public var start: Double
    public var end: Double

    public init(vector: [Float], start: Double, end: Double) {
        self.vector = vector
        self.start = start
        self.end = end
    }
}

/// One stretch of a line spoken by one voice. `voice` is nil when the speaker
/// can't be told (no usable prints, or a short line matching nobody).
public struct VoicePiece: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var voice: String?
    public var exchange: Int

    public init(start: Double, end: Double, voice: String?, exchange: Int) {
        self.start = start
        self.end = end
        self.voice = voice
        self.exchange = exchange
    }
}

/// Splits a line where the voice changes and gives each piece a letter for
/// its voice within the current exchange. Letters are never rewritten.
public struct VoiceTracker: Sendable {
    /// A change leaving a piece shorter than this many seconds is ignored.
    static let minimumPiece = 0.8
    /// Short lines match a known voice within threshold times this.
    static let shortLineLooseness = 1.25

    private struct Voice: Sendable {
        var sum: [Float]
        var count: Int
    }

    private let settings: VoiceChangeSettings
    private var voices: [Voice] = []
    private var exchange = 1
    private var lastLineEnd: Double?

    public init(settings: VoiceChangeSettings) {
        self.settings = settings
    }

    /// 0 is "A", 25 is "Z", 26 is "AA", 27 is "AB".
    public static func letter(_ index: Int) -> String {
        var n = max(index, 0)
        var out = ""
        repeat {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    public mutating func assign(_ prints: [Voiceprint], lineStart: Double, lineEnd: Double) -> [VoicePiece] {
        if let last = lastLineEnd, lineStart - last > settings.exchangeGap {
            exchange += 1
            voices = []
        }
        lastLineEnd = lineEnd

        let usable = usablePrints(prints)
        guard !usable.isEmpty else {
            return [VoicePiece(start: lineStart, end: lineEnd, voice: nil, exchange: exchange)]
        }

        // Change points: neighbouring prints further apart than the threshold,
        // unless the change would leave a piece that's too short.
        var groups: [[Voiceprint]] = [[usable[0]]]
        var boundaries: [Double] = []
        var pieceStart = lineStart
        for i in 1..<usable.count {
            let boundary = Self.changeTime(from: usable[i - 1], to: usable[i])
            let changed = Self.distance(usable[i - 1].vector, usable[i].vector) > settings.threshold
            if changed, boundary - pieceStart >= Self.minimumPiece, lineEnd - boundary >= Self.minimumPiece {
                groups.append([usable[i]])
                boundaries.append(boundary)
                pieceStart = boundary
            } else {
                groups[groups.count - 1].append(usable[i])
            }
        }

        var pieces: [VoicePiece] = []
        for (i, group) in groups.enumerated() {
            let start = i == 0 ? lineStart : boundaries[i - 1]
            let end = i == groups.count - 1 ? lineEnd : boundaries[i]
            let voice = resolve(group, duration: end - start)
            pieces.append(VoicePiece(start: start, end: end, voice: voice, exchange: exchange))
        }
        return pieces
    }

    // MARK: - Voices

    private mutating func resolve(_ group: [Voiceprint], duration: Double) -> String? {
        let dim = group[0].vector.count
        var sum = [Float](repeating: 0, count: dim)
        for p in group { for k in 0..<dim { sum[k] += p.vector[k] } }
        guard let mean = Self.normalised(sum) else { return nil }

        var nearest: (index: Int, distance: Double)?
        for (i, voice) in voices.enumerated() where voice.sum.count == dim {
            guard let m = Self.normalised(voice.sum) else { continue }
            let d = Self.distance(mean, m)
            if nearest == nil || d < nearest!.distance { nearest = (i, d) }
        }

        if let n = nearest, n.distance <= settings.threshold {
            for k in 0..<dim { voices[n.index].sum[k] += sum[k] }
            voices[n.index].count += group.count
            return Self.letter(n.index)
        }
        if duration < settings.shortLine {
            if let n = nearest, n.distance <= settings.threshold * Self.shortLineLooseness {
                return Self.letter(n.index)
            }
            return nil
        }
        voices.append(Voice(sum: sum, count: group.count))
        return Self.letter(voices.count - 1)
    }

    // MARK: - Maths

    /// When the voice changed, given the last print of the old voice and the
    /// first of the new: halfway between their middles, which is what each
    /// print describes best. For prints that don't overlap that's where the
    /// new one starts. For the voice model's overlapping 1.5 s windows the
    /// new print's start is most of a word too early. Erring a little early
    /// is safer than late: the pause before a new speaker lies just before
    /// the change, and the splitter snaps to it.
    static func changeTime(from old: Voiceprint, to new: Voiceprint) -> Double {
        ((old.start + old.end) / 2 + (new.start + new.end) / 2) / 2
    }

    /// Prints with finite, non-zero vectors of one consistent size (that of the
    /// known voices, or of the first usable print), each re-normalised.
    private func usablePrints(_ prints: [Voiceprint]) -> [Voiceprint] {
        var dim = voices.first?.sum.count
        var out: [Voiceprint] = []
        for p in prints {
            if let d = dim, p.vector.count != d { continue }
            guard let v = Self.normalised(p.vector) else { continue }
            dim = v.count
            out.append(Voiceprint(vector: v, start: p.start, end: p.end))
        }
        return out
    }

    private static func normalised(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        var sq: Float = 0
        for x in v { sq += x * x }
        guard sq.isFinite, sq > 1e-12 else { return nil }
        let inv = 1 / sq.squareRoot()
        return v.map { $0 * inv }
    }

    /// Cosine distance of two L2-normalised vectors of equal size.
    private static func distance(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0
        for k in 0..<a.count { dot += a[k] * b[k] }
        return Double(1 - dot)
    }
}
