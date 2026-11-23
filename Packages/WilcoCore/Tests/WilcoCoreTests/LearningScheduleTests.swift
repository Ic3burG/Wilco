import Foundation
import Testing
@testable import WilcoCore

@Suite struct LearningScheduleTests {
    @Test func scheduleNeverRunsWhileCapturing() {
        #expect(!LearningSchedule.mayRun(now: .now, capturing: true, lastCaptureStop: nil))
        #expect(!LearningSchedule.mayRun(now: .now, capturing: true, lastCaptureStop: .distantPast))
    }

    @Test func scheduleWaitsTwoMinutesAfterStopping() {
        let stop = Date(timeIntervalSince1970: 1_000_000)
        #expect(!LearningSchedule.mayRun(now: stop.addingTimeInterval(119), capturing: false, lastCaptureStop: stop))
        #expect(LearningSchedule.mayRun(now: stop.addingTimeInterval(120), capturing: false, lastCaptureStop: stop))
    }

    @Test func scheduleRunsAtLaunch() {
        #expect(LearningSchedule.mayRun(now: .now, capturing: false, lastCaptureStop: nil))
    }
}
