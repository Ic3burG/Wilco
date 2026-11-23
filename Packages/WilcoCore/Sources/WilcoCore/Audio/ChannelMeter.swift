import Accelerate
import Foundation

/// A few seconds of one channel's audio, kept in memory for the classifier.
public struct MeterClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// A finished minute and, when the channel had sound, a clip of it.
public struct MeterReport: Sendable {
    public var row: ChannelMinute
    public var clip: MeterClip?

    public init(row: ChannelMinute, clip: MeterClip? = nil) {
        self.row = row
        self.clip = clip
    }
}

/// Where a session's meters send their finished minutes.
public struct DiagnosticsTap: Sendable {
    public var sessionStart: Date
    public var sink: @Sendable (MeterReport) -> Void

    public init(sessionStart: Date, sink: @escaping @Sendable (MeterReport) -> Void) {
        self.sessionStart = sessionStart
        self.sink = sink
    }
}

/// Measures one channel's audio a minute at a time. Feed it every block the
/// engine reads; it sends a ``MeterReport`` to the tap when a minute ends.
/// It runs in a transcriber's read loop, never in the capture callback.
public struct ChannelMeter: Sendable {
    private static let histogramLow = -120
    private static let binCount = 120
    private static let frameSeconds = 0.02

    private struct Minute {
        var index: Int
        var audio = 0.0
        var sound = 0.0
        var soundSquares = 0.0
        var soundSamples = 0
        var peak: Float = 0
        var clipped = 0
        var histogram = [Int](repeating: 0, count: ChannelMeter.binCount)
        var frames = 0
        var droppedStart: Int
        var droppedLast: Int
        var droppedRate = 0.0
        var utterances = 0
        var speech = 0.0
        var cuts = 0
        var recognize = 0.0
        var clip: MeterClip?
    }

    private let channelID: UUID
    private let tap: DiagnosticsTap
    private let countsUtterances: Bool
    private let clipSeconds: Double

    private var minute: Minute?
    private var emittedAny = false
    /// Samples left over from the last block that didn't fill a frame.
    private var carry: [Float] = []
    private var rate = 0.0
    /// The clip being gathered, which starts at a sound frame.
    private var gathering: [Float]?

    public init(channelID: UUID, tap: DiagnosticsTap, countsUtterances: Bool, clipSeconds: Double = 3) {
        self.channelID = channelID
        self.tap = tap
        self.countsUtterances = countsUtterances
        self.clipSeconds = clipSeconds
    }

    /// dBFS of a linear amplitude; nil for silence.
    static func decibels(_ amplitude: Double) -> Double? {
        amplitude > 0 ? 20 * log10(amplitude) : nil
    }

    /// Adds a block read at `now`. Call it on every read, even an empty one,
    /// so minutes close while a channel gets no audio. The whole block counts
    /// towards the minute `now` falls in.
    public mutating func add(_ samples: [Float], sampleRate: Double, droppedFrames: Int, at now: Date) {
        let index = Int((now.timeIntervalSince(tap.sessionStart) / 60).rounded(.down))
        if let current = minute, current.index < index {
            emit(current, nextIndex: index)
        }
        if minute == nil {
            minute = Minute(index: index, droppedStart: droppedFrames, droppedLast: droppedFrames)
        }
        minute?.droppedLast = droppedFrames
        guard sampleRate > 0, !samples.isEmpty else { return }

        if sampleRate != rate {
            rate = sampleRate
            carry = []
            gathering = nil
        }
        minute?.droppedRate = sampleRate
        minute?.audio += Double(samples.count) / sampleRate
        measure(samples, sampleRate: sampleRate)
    }

    /// Records one recognised utterance: the model's time, the seconds of
    /// audio it covered, and whether it was cut at the length limit. Ignored
    /// before the first `add`.
    public mutating func recognized(modelSeconds: Double, audioSeconds: Double, cut: Bool) {
        guard minute != nil else { return }
        minute?.utterances += 1
        minute?.speech += audioSeconds
        minute?.recognize += modelSeconds
        if cut { minute?.cuts += 1 }
    }

    /// Emits the minute in progress, marked partial, when capture stops.
    /// The date is not used; the minute is the one in progress. A meter used
    /// again afterwards starts with a partial minute.
    public mutating func finish(at now: Date) {
        defer { emittedAny = false }
        guard let current = minute else { return }
        minute = nil
        carry = []
        gathering = nil
        send(current, partial: true)
    }

    private mutating func emit(_ current: Minute, nextIndex: Int) {
        let dropped = current.droppedLast
        minute = Minute(index: nextIndex, droppedStart: dropped, droppedLast: dropped)
        gathering = nil
        send(current, partial: !emittedAny)
    }

    private mutating func send(_ m: Minute, partial: Bool) {
        emittedAny = true
        let rms = m.soundSamples > 0 ? Self.decibels((m.soundSquares / Double(m.soundSamples)).squareRoot()) : nil
        let dropped = m.droppedLast - m.droppedStart
        let row = ChannelMinute(
            channel: channelID, minute: m.index, audio: m.audio, sound: m.sound,
            rms: rms, peak: Self.decibels(Double(m.peak)), floor: floorLevel(m),
            clipped: m.clipped, dropped: dropped,
            droppedSeconds: m.droppedRate > 0 ? Double(dropped) / m.droppedRate : 0,
            utterances: countsUtterances ? m.utterances : nil,
            speech: countsUtterances ? m.speech : nil,
            cuts: countsUtterances ? m.cuts : nil,
            recognize: countsUtterances ? m.recognize : nil,
            partial: partial ? true : nil)
        tap.sink(MeterReport(row: row, clip: m.clip))
    }

    /// The 10th-percentile level of non-silent frames, from the histogram.
    /// Nil when there were none (every frame digital silence).
    private func floorLevel(_ m: Minute) -> Double? {
        guard m.frames > 0 else { return nil }
        let target = Int((Double(m.frames) * 0.1).rounded(.up))
        var seen = 0
        for (bin, count) in m.histogram.enumerated() {
            seen += count
            if seen >= target { return Double(Self.histogramLow + bin) + 0.5 }
        }
        return nil
    }

    private mutating func measure(_ samples: [Float], sampleRate: Double) {
        // Take the minute out so mutating it doesn't copy its histogram.
        guard var m = minute else { return }
        minute = nil
        let frameLength = max(1, Int(sampleRate * Self.frameSeconds))
        let all = carry.isEmpty ? samples : carry + samples
        let clipTarget = Int(clipSeconds * sampleRate)

        samples.withUnsafeBufferPointer { block in
            guard let base = block.baseAddress else { return }
            var blockPeak: Float = 0
            vDSP_maxmgv(base, 1, &blockPeak, vDSP_Length(block.count))
            if blockPeak >= ReviewThresholds.clipLevel {
                for sample in block where abs(sample) >= ReviewThresholds.clipLevel { m.clipped += 1 }
            }
            m.peak = max(m.peak, blockPeak)
        }
        all.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }

            var offset = 0
            while buffer.count - offset >= frameLength {
                let frame = base + offset
                var squares: Float = 0
                vDSP_svesq(frame, 1, &squares, vDSP_Length(frameLength))
                let level = (squares / Float(frameLength)).squareRoot()
                offset += frameLength

                // Digital silence stays out of the histogram: the floor is the
                // quietest level of frames that carried any signal.
                if let decibels = Self.decibels(Double(level)) {
                    m.frames += 1
                    let bin = Int(decibels.rounded(.down)) - Self.histogramLow
                    m.histogram[min(Self.binCount - 1, max(0, bin))] += 1
                }
                let isSound = level > ReviewThresholds.soundFloor
                if isSound {
                    m.sound += Self.frameSeconds
                    m.soundSquares += Double(squares)
                    m.soundSamples += frameLength
                }
                guard m.clip == nil else { continue }
                if gathering == nil, isSound { gathering = [] }
                if gathering != nil {
                    gathering?.append(contentsOf: UnsafeBufferPointer(start: frame, count: frameLength))
                    if let gathered = gathering, gathered.count >= clipTarget, clipTarget > 0 {
                        m.clip = MeterClip(samples: Array(gathered.prefix(clipTarget)), sampleRate: sampleRate)
                        gathering = nil
                    }
                }
            }
            carry = Array(buffer[offset...])
        }
        minute = m
    }
}
