import Foundation

/// When clips may be labelled: never during capture, and not until a while
/// after it stops, so labelling doesn't compete with a show that restarts.
public enum LearningSchedule {
    /// Seconds to wait after capture stops.
    public static let delayAfterCapture: Double = 120

    public static func mayRun(now: Date, capturing: Bool, lastCaptureStop: Date?) -> Bool {
        if capturing { return false }
        guard let lastCaptureStop else { return true }
        return now.timeIntervalSince(lastCaptureStop) >= delayAfterCapture
    }
}
