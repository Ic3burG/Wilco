import Foundation

/// Settings › General: preferences for this Mac, kept in `UserDefaults`,
/// never in a show. A show file can't switch any of them on.
///
/// Every default is the safe one: Wilco never starts listening on its own
/// unless the operator turned that on here.
public enum GeneralPreferences {
    /// Keep the display awake too while capturing. The Mac itself is always
    /// kept awake during a capture; this only adds the screen.
    public static let keepsDisplayAwakeKey = "capture.keepsDisplayAwake"
    public static let keepsDisplayAwakeDefault = false

    /// Ask before quitting while capture is running.
    public static let asksToQuitWhileCapturingKey = "quit.asksWhileCapturing"
    public static let asksToQuitWhileCapturingDefault = true

    /// Start capture as soon as Wilco opens.
    public static let startsCaptureOnLaunchKey = "launch.startsCapture"
    public static let startsCaptureOnLaunchDefault = false

    public static func keepsDisplayAwake(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepsDisplayAwakeKey) as? Bool ?? keepsDisplayAwakeDefault
    }

    public static func asksToQuitWhileCapturing(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: asksToQuitWhileCapturingKey) as? Bool ?? asksToQuitWhileCapturingDefault
    }

    public static func startsCaptureOnLaunch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: startsCaptureOnLaunchKey) as? Bool ?? startsCaptureOnLaunchDefault
    }

    /// What to ask the system for while capturing: no idle sleep and no App
    /// Nap (`userInitiated`), plus the display when asked. The lid, the
    /// power button and the Apple menu's Sleep still sleep the Mac.
    public static func captureActivity(keepsDisplayAwake: Bool) -> ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if keepsDisplayAwake { options.insert(.idleDisplaySleepDisabled) }
        return options
    }

    /// Whether quitting now should first ask to end the capture.
    public static func asksBeforeQuitting(capturing: Bool, asksWhileCapturing: Bool) -> Bool {
        capturing && asksWhileCapturing
    }
}
