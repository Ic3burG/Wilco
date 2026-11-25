import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite struct DiagnosticsRecorderTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let channel = UUID()
    let shares = SoundShares(speech: 0.9, music: 0.1, singing: 0)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.diagnostics")
    }

    private func recorder(
        _ url: URL, hold: Double = 30, classifier: SoundClassifierQueue? = nil, at offset: Double = 0
    ) -> (DiagnosticsRecorder, ManualDate) {
        let clock = ManualDate(start.addingTimeInterval(offset))
        let r = DiagnosticsRecorder(
            writer: DiagnosticsWriter(url: url), sessionStart: start, classifier: classifier,
            hold: hold, now: { clock.date }, writeInterval: nil)
        return (r, clock)
    }

    private func row(_ minute: Int, audio: Double = 60, partial: Bool? = nil) -> ChannelMinute {
        ChannelMinute(channel: channel, minute: minute, audio: audio, sound: 10, partial: partial)
    }

    private func clip() -> MeterClip { MeterClip(samples: [0.1, 0.2], sampleRate: 16000) }

    /// Reports reach the recorder through a stream; wait for them to land.
    private func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fileRows(_ url: URL) -> [ChannelMinute] {
        DiagnosticsFile.rows(in: (try? Data(contentsOf: url)) ?? Data())
    }

    @Test func mergesARestartedChannelsMinute() async {
        let url = tempURL()
        let (r, clock) = recorder(url)
        r.tap.sink(MeterReport(row: row(12, audio: 20, partial: true)))
        r.tap.sink(MeterReport(row: row(12, audio: 30, partial: true)))
        await waitFor { await r.heldRowCount == 1 }
        clock.date = start.addingTimeInterval(13.6 * 60 + 30)
        await r.writeDue()
        let rows = fileRows(url)
        #expect(rows.count == 1)
        #expect(rows.first?.audio == 50)
        #expect(rows.first?.partial == true)
        await r.finish()
    }

    @Test func waitsForClassification() async {
        let url = tempURL()
        let queue = SoundClassifierQueue { [shares] _ in
            try? await Task.sleep(for: .milliseconds(50))
            return shares
        }
        let (r, clock) = recorder(url, classifier: queue)
        r.tap.sink(MeterReport(row: row(0), clip: clip()))
        await waitFor { await r.heldRowCount == 1 }
        await waitFor { await r.pendingClassifications == 0 }
        clock.date = start.addingTimeInterval(60 + 31)
        await r.writeDue()
        #expect(fileRows(url).first?.classified == shares)
        await r.finish()
    }

    @Test func writesWithoutClassificationAfterHold() async {
        let url = tempURL()
        let queue = SoundClassifierQueue { _ in
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }
        let (r, clock) = recorder(url, hold: 0.5, classifier: queue)
        r.tap.sink(MeterReport(row: row(0), clip: clip()))
        await waitFor { await r.heldRowCount == 1 }
        clock.date = start.addingTimeInterval(60 + 1)
        await r.writeDue()
        let rows = fileRows(url)
        #expect(rows.count == 1)
        #expect(rows.first?.classified == nil)
        await r.finish()
    }

    @Test func finishWritesEverythingAndReturns() async {
        let url = tempURL()
        let queue = SoundClassifierQueue { _ in
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }
        let (r, _) = recorder(url, hold: 0.2, classifier: queue)
        for minute in 0..<3 { r.tap.sink(MeterReport(row: row(minute), clip: clip())) }
        let began = Date()
        await r.finish()
        // The classifier never answers (an hour), so finish must stop after
        // the 0.2 s hold. The bound is loose because a busy CI runner has
        // taken 6 s here; it only has to rule out waiting on the classifier.
        #expect(Date().timeIntervalSince(began) < 30)
        #expect(fileRows(url).map(\.minute) == [0, 1, 2])
    }

    @Test func rowsNotYetDueStayHeld() async {
        let url = tempURL()
        let (r, clock) = recorder(url)
        r.tap.sink(MeterReport(row: row(0)))
        await waitFor { await r.heldRowCount == 1 }
        clock.date = start.addingTimeInterval(60 + 10)
        await r.writeDue()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await r.finish()
    }

    @Test func finishDoesNotWaitOnClassificationsOfWrittenRows() async {
        let url = tempURL()
        let queue = SoundClassifierQueue { _ in
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }
        let (r, clock) = recorder(url, hold: 5, classifier: queue)
        r.tap.sink(MeterReport(row: row(0), clip: clip()))
        await waitFor { await r.pendingClassifications == 1 }
        clock.date = start.addingTimeInterval(60 + 6)
        await r.writeDue()
        #expect(fileRows(url).count == 1)
        r.tap.sink(MeterReport(row: row(1)))
        await waitFor { await r.heldRowCount == 1 }
        let began = Date()
        await r.finish()
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(fileRows(url).map(\.minute) == [0, 1])
    }

    @Test func aWriteFailureForgetsRowsWithoutCrashing() async throws {
        let blocker = tempURL()
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let (r, clock) = recorder(blocker.appendingPathComponent("s.diagnostics"))
        r.tap.sink(MeterReport(row: row(0)))
        await waitFor { await r.heldRowCount == 1 }
        clock.date = start.addingTimeInterval(60 + 31)
        await r.writeDue()
        r.tap.sink(MeterReport(row: row(1)))
        await waitFor { await r.heldRowCount == 1 }
        clock.date = start.addingTimeInterval(120 + 31)
        await r.writeDue()
        #expect(await r.heldRowCount == 0)
        await r.finish()
    }

    @Test func holdsARowWhileItsClassificationIsPending() async {
        let url = tempURL()
        let release = Release()
        let queue = SoundClassifierQueue { [shares] _ in
            while !release.isSet { try? await Task.sleep(for: .milliseconds(5)) }
            return shares
        }
        let (r, clock) = recorder(url, classifier: queue)
        r.tap.sink(MeterReport(row: row(0), clip: clip()))
        await waitFor { await r.pendingClassifications == 1 }
        clock.date = start.addingTimeInterval(60 + 10)
        await r.writeDue()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await r.heldRowCount == 1)
        release.set()
        await waitFor { await r.pendingClassifications == 0 }
        clock.date = start.addingTimeInterval(60 + 31)
        await r.writeDue()
        #expect(fileRows(url).first?.classified == shares)
        await r.finish()
    }
}

fileprivate final class Release: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// A date the test moves by hand.
fileprivate final class ManualDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}