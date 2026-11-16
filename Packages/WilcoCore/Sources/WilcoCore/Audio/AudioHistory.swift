import Foundation

/// The most recent stretch of a channel's audio, keyed by session offset, so
/// the audio behind a line can be fetched after the line is recognised.
///
/// Bounded: once full, the oldest audio is overwritten. Appended to by a
/// transcriber's pump, never by the capture callback. Assumes the audio it is
/// given is continuous: each append ends where the samples it holds end.
public struct AudioHistory: Sendable {
    public let sampleRate: Double
    private var buffer: [Float]
    /// Where the next sample goes.
    private var writeIndex = 0
    /// Samples held, up to the buffer's size.
    private var count = 0
    /// Session offset of the end of the newest sample.
    private var endOffset: Double = 0

    public init(sampleRate: Double = 16_000, seconds: Double = 30) {
        self.sampleRate = sampleRate
        buffer = [Float](repeating: 0, count: max(Int(sampleRate * seconds), 1))
    }

    /// Adds `samples`, the last of which ends `offset` seconds into the session.
    public mutating func append(_ samples: [Float], endingAt offset: Double) {
        endOffset = offset
        guard !samples.isEmpty else { return }
        let capacity = buffer.count
        // Only the newest `capacity` samples can be kept.
        let kept = samples.count > capacity ? samples[(samples.count - capacity)...] : samples[...]
        buffer.withUnsafeMutableBufferPointer { out in
            var index = writeIndex
            for sample in kept {
                out[index] = sample
                index += 1
                if index == capacity { index = 0 }
            }
            writeIndex = index
        }
        count = min(count + kept.count, capacity)
    }

    /// Adds the next `seconds` of audio, moving the timeline on by exactly
    /// that much. Nil `samples` (audio that couldn't be converted) adds
    /// silence of that length, so later audio is still found where it was
    /// heard.
    public mutating func append(_ samples: [Float]?, lasting seconds: Double) {
        let end = endOffset + seconds
        if let samples {
            append(samples, endingAt: end)
        } else {
            append([Float](repeating: 0, count: Int((seconds * sampleRate).rounded())), endingAt: end)
        }
    }

    /// The audio between two session offsets. Any part older than the history,
    /// or newer than its last sample, is left out.
    public func samples(from start: Double, to end: Double) -> [Float] {
        guard count > 0, end > start else { return [] }
        let oldest = endOffset - Double(count) / sampleRate
        let first = max(Int(((start - oldest) * sampleRate).rounded()), 0)
        let last = min(Int(((end - oldest) * sampleRate).rounded()), count)
        guard first < last else { return [] }
        let capacity = buffer.count
        // The oldest held sample sits at `writeIndex` once the buffer has wrapped.
        let base = count == capacity ? writeIndex : 0
        var out = [Float]()
        out.reserveCapacity(last - first)
        for i in first..<last {
            out.append(buffer[(base + i) % capacity])
        }
        return out
    }
}
