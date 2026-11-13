import Darwin
import Synchronization

/// Single-producer, single-consumer ring of mono samples.
///
/// The audio thread writes and one transcriber reads. Neither side allocates,
/// locks or waits, so `write` is safe to call from a CoreAudio IOProc. When the
/// reader falls behind, new frames are dropped rather than overwriting audio
/// the reader has not seen.
public final class AudioRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames ever written / read. Their difference is the fill level.
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    /// Uptime of the last read, in nanoseconds; 0 if never read.
    private let lastReadNanos = Atomic<UInt64>(0)
    /// A reader quiet for longer than this has gone away (e.g. channel muted).
    private static let consumerTimeoutNanos: UInt64 = 2_000_000_000

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    public var availableToRead: Int {
        written.load(ordering: .acquiring) - consumed.load(ordering: .relaxed)
    }

    /// Frames discarded because the reader fell behind. A ring nobody is
    /// reading fills up by design, so frames it discards are not counted.
    public var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    private var hasActiveConsumer: Bool {
        let last = lastReadNanos.load(ordering: .relaxed)
        return last != 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last < Self.consumerTimeoutNanos
    }

    /// Producer side. Copies `count` samples, taking every `stride`-th value
    /// from `source` (so an interleaved buffer can be read one channel at a time).
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int, stride: Int = 1) -> Int {
        let head = written.load(ordering: .relaxed)
        let tail = consumed.load(ordering: .acquiring)
        let accepted = min(count, capacity - (head - tail))
        for i in 0..<accepted {
            storage[(head + i) % capacity] = source[i * stride]
        }
        written.store(head + accepted, ordering: .releasing)
        if accepted < count, hasActiveConsumer {
            dropped.add(count - accepted, ordering: .relaxed)
        }
        return accepted
    }

    /// Consumer side. Copies up to `maxCount` samples into `destination`.
    public func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        lastReadNanos.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        let tail = consumed.load(ordering: .relaxed)
        let head = written.load(ordering: .acquiring)
        let count = min(maxCount, head - tail)
        for i in 0..<count {
            destination[i] = storage[(tail + i) % capacity]
        }
        consumed.store(tail + count, ordering: .releasing)
        return count
    }
}

extension AudioRingBuffer {
    /// Convenience for non-real-time callers and tests.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0.baseAddress!, count: $0.count) }
    }

    public func read(maxCount: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: min(maxCount, availableToRead)) { buffer, initialized in
            initialized = read(into: buffer.baseAddress!, maxCount: buffer.count)
        }
    }
}
