import Foundation
import Synchronization
import Testing
@testable import WilcoCore

@Suite("Clip switch")
struct ClipSwitchTests {
    private let tap = ClipTap { _ in }

    @Test func startsOffAndOffersNothing() {
        let clips = ClipSwitch()
        #expect(!clips.isOn)
        #expect(clips.tap(forLineStartingAt: 0) == nil)
    }

    @Test func turnedOnAtTheStartTakesEveryLine() {
        let clips = ClipSwitch()
        clips.turnOn(tap)
        #expect(clips.isOn)
        #expect(clips.tap(forLineStartingAt: 0) != nil)
        #expect(clips.tap(forLineStartingAt: 3_600) != nil)
    }

    @Test func turnedOnMidCaptureSkipsLinesAlreadyUnderWay() {
        // A line that began before the switch may be missing the audio
        // from before it, so only lines from then on are kept.
        let clips = ClipSwitch()
        clips.turnOn(tap, from: 120)
        #expect(clips.tap(forLineStartingAt: 119.9) == nil)
        #expect(clips.tap(forLineStartingAt: 120) != nil)
        #expect(clips.tap(forLineStartingAt: 130) != nil)
    }

    @Test func turnedOffStopsAtOnceAndCanComeBack() {
        let offered = Mutex(0)
        let counting = ClipTap { _ in offered.withLock { $0 += 1 } }
        let clips = ClipSwitch()
        clips.turnOn(counting)
        clips.turnOff()
        #expect(!clips.isOn)
        #expect(clips.tap(forLineStartingAt: 10) == nil)

        clips.turnOn(counting, from: 50)
        clips.tap(forLineStartingAt: 60)?.offer(ClipOffer(
            candidate: ClipCandidate(id: UUID(), channel: UUID(), sessionOffset: 60, duration: 1, confidence: nil),
            engine: "parakeet", samples: []
        ))
        #expect(offered.withLock { $0 } == 1)
    }
}
