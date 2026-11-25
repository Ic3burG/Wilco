import Foundation
import Testing
@testable import WilcoCore

@Suite("General preferences")
struct GeneralPreferencesTests {
    typealias Prefs = GeneralPreferences

    static func freshDefaults() throws -> UserDefaults {
        let name = "wilco-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// Nothing listens or keeps the screen on unless the operator chose it.
    @Test func defaultsAreTheSafeOnes() throws {
        let defaults = try Self.freshDefaults()
        #expect(Prefs.startsCaptureOnLaunch(in: defaults) == false)
        #expect(Prefs.keepsDisplayAwake(in: defaults) == false)
        #expect(Prefs.asksToQuitWhileCapturing(in: defaults) == true)
    }

    @Test func storedValuesWin() throws {
        let defaults = try Self.freshDefaults()
        defaults.set(true, forKey: Prefs.startsCaptureOnLaunchKey)
        defaults.set(true, forKey: Prefs.keepsDisplayAwakeKey)
        defaults.set(false, forKey: Prefs.asksToQuitWhileCapturingKey)
        #expect(Prefs.startsCaptureOnLaunch(in: defaults))
        #expect(Prefs.keepsDisplayAwake(in: defaults))
        #expect(!Prefs.asksToQuitWhileCapturing(in: defaults))
    }

    @Test func aHandEditedValueOfTheWrongTypeFallsBack() throws {
        let defaults = try Self.freshDefaults()
        defaults.set("yes please", forKey: Prefs.startsCaptureOnLaunchKey)
        #expect(Prefs.startsCaptureOnLaunch(in: defaults) == false)
    }

    @Test func captureKeepsTheMacAwakeAndOnlyTheDisplayIsOptional() {
        let plain = Prefs.captureActivity(keepsDisplayAwake: false)
        #expect(plain.contains(.idleSystemSleepDisabled))
        #expect(plain.contains(.userInitiated))
        #expect(!plain.contains(.idleDisplaySleepDisabled))
        #expect(Prefs.captureActivity(keepsDisplayAwake: true).contains(.idleDisplaySleepDisabled))
    }

    @Test func asksBeforeQuittingOnlyWhileCapturing() {
        #expect(Prefs.asksBeforeQuitting(capturing: true, asksWhileCapturing: true))
        #expect(!Prefs.asksBeforeQuitting(capturing: true, asksWhileCapturing: false))
        #expect(!Prefs.asksBeforeQuitting(capturing: false, asksWhileCapturing: true))
    }
}
