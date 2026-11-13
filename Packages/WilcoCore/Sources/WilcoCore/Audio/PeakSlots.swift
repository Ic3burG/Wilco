import Synchronization

/// Per-channel peak levels shared between the audio thread and the UI.
///
/// The audio thread raises a slot to the loudest sample it saw; the UI takes
/// the value and resets it, so each meter reading is the peak since the last.
public final class PeakSlots: @unchecked Sendable {
    public let count: Int
    /// Float bit patterns, so the slots can be atomic.
    private let slots: UnsafeMutablePointer<Atomic<UInt32>>

    public init(count: Int) {
        self.count = count
        slots = .allocate(capacity: max(count, 1))
        for index in 0..<count {
            (slots + index).initialize(to: Atomic(0))
        }
    }

    deinit {
        slots.deinitialize(count: count)
        slots.deallocate()
    }

    /// Real-time safe.
    public func record(_ peak: Float, at slot: Int) {
        var current = slots[slot].load(ordering: .relaxed)
        while peak > Float(bitPattern: current) {
            let (exchanged, original) = slots[slot].compareExchange(
                expected: current, desired: peak.bitPattern, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }

    public func take(_ slot: Int) -> Float {
        Float(bitPattern: slots[slot].exchange(0, ordering: .relaxed))
    }
}
