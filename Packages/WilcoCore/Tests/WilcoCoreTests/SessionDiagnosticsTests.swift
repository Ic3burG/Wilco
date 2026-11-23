import Foundation
import Testing
@testable import WilcoCore

@Suite struct SessionDiagnosticsTests {
    let channel = UUID()

    func row(_ minute: Int, audio: Double = 60, sound: Double = 0, rms: Double? = nil, peak: Double? = nil,
             clipped: Int = 0, partial: Bool? = nil, speech: Double? = nil, cuts: Int? = nil,
             classified: SoundShares? = nil, droppedSeconds: Double = 0) -> ChannelMinute {
        ChannelMinute(channel: channel, minute: minute, audio: audio, sound: sound, rms: rms, peak: peak,
                      clipped: clipped, droppedSeconds: droppedSeconds, speech: speech, cuts: cuts,
                      partial: partial, classified: classified)
    }

    func lost(_ rows: [ChannelMinute]) -> [Int]? { SessionDiagnostics.make(rows).channels[channel]?.lostMinutes }

    @Test func summarisesLevelsAndSound() {
        let d = SessionDiagnostics.make([
            row(0, sound: 5, rms: 0.1, peak: 0.5, clipped: 1, droppedSeconds: 1),
            row(1, sound: 0.5, rms: 0.001, peak: 0.9),
            row(2, sound: 10, rms: 0.2, peak: 0.7, droppedSeconds: 2),
        ]).channels[channel]
        #expect(d?.minutes == 3)
        #expect(d?.soundMinutes == 2)
        #expect(d?.soundSeconds == 15.5)
        #expect(d?.peak == 0.9)
        #expect(d?.medianRMS == 0.2)
        #expect(d?.clippedSoundMinuteShare == 0.5)
        #expect(d?.droppedSeconds == 3)
    }

    @Test func noSoundGivesZeroShareAndNilMedian() {
        let d = SessionDiagnostics.make([row(0)]).channels[channel]
        #expect(d?.clippedSoundMinuteShare == 0)
        #expect(d?.medianRMS == nil)
        #expect(d?.peak == nil)
    }

    @Test func shortMinuteCountsAsLostUnlessPartial() {
        #expect(lost([row(0, partial: true), row(1, audio: 30), row(2), row(3, audio: 10, partial: true)]) == [1])
    }

    @Test func gapAfterFullRowIsLost() {
        #expect(lost([row(0, partial: true), row(1), row(4), row(5, partial: true)]) == [2, 3])
    }

    @Test func gapAfterStopIsNotLost() {
        #expect(lost([row(0, partial: true), row(1), row(2, partial: true), row(7, partial: true), row(8, partial: true)]) == [])
    }

    @Test func unsortedAndDuplicateRowsAreNormalised() {
        let d = SessionDiagnostics.make([row(2, audio: 30, partial: true), row(0, partial: true), row(1, audio: 30, sound: 2), row(1, audio: 30, sound: 3)]).channels[channel]
        #expect(d?.minutes == 3)
        #expect(d?.soundSeconds == 5)
        #expect(d?.soundMinutes == 1)
        #expect(d?.lostMinutes == [])
    }

    @Test func musicAndSpeechMinutes() {
        // The row's own `speech` (seconds sent to the model) must not matter.
        let d = SessionDiagnostics.make([
            row(0, sound: 30, speech: 0, classified: SoundShares(speech: 0.9, music: 0.1, singing: 0)),
            row(1, sound: 30, speech: 40, classified: SoundShares(speech: 0.2, music: 0, singing: 0.7)),
            row(2, sound: 30, speech: 40, classified: SoundShares(speech: 0.1, music: 0.3, singing: 0)),
            row(3, sound: 0, classified: SoundShares(speech: 0, music: 1, singing: 0)),
            row(4, sound: 30, speech: 40),
        ]).channels[channel]
        #expect(d?.classifiedSoundMinutes == 3)
        #expect(d?.speechMinutes == 1)
        #expect(d?.musicMinutes == 2)
    }

    @Test func cutsNilForAppleEngine() {
        #expect(SessionDiagnostics.make([row(0), row(1)]).channels[channel]?.cuts == nil)
        #expect(SessionDiagnostics.make([row(0), row(1, cuts: 2)]).channels[channel]?.cuts == 2)
    }

    @Test func loadReturnsNilWithoutFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transcript = dir.appendingPathComponent("Session 2026-01-01 1000-00.jsonl")
        #expect(SessionDiagnostics.load(forTranscript: transcript) == nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: DiagnosticsFile.url(forTranscript: transcript))
        #expect(SessionDiagnostics.load(forTranscript: transcript) == nil)
        try DiagnosticsFile.line(for: row(0, sound: 2)).write(to: DiagnosticsFile.url(forTranscript: transcript))
        #expect(SessionDiagnostics.load(forTranscript: transcript)?.channels[channel]?.soundMinutes == 1)
    }
}
