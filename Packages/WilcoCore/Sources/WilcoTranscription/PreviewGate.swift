/// Keeps previews out of the way of final lines on a model every channel
/// shares. Final lines never wait here: they are only counted. A preview
/// runs only while no final line is in flight and no other preview runs,
/// and otherwise is skipped rather than queued, so previews can't build up
/// in front of the lines rules fire on.
public actor PreviewGate {
    /// Final transcriptions started and not yet ended.
    public private(set) var finalsInFlight = 0
    private var previewRunning = false

    public init() {}

    public func beginFinal() {
        finalsInFlight += 1
    }

    public func endFinal() {
        finalsInFlight = max(0, finalsInFlight - 1)
    }

    /// True if the caller may run a preview now; it must then call
    /// ``endPreview()``. False means skip this preview.
    public func tryBeginPreview() -> Bool {
        guard finalsInFlight == 0, !previewRunning else { return false }
        previewRunning = true
        return true
    }

    public func endPreview() {
        previewRunning = false
    }
}
