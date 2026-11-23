import Foundation
import Synchronization
import Testing
@testable import WilcoCore

@Suite("Channel meter")
struct ChannelMeterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let channel = UUID()

    private final class Collector: Sendable {
        let reports = Mutex<[MeterReport]>([])
        func add(_ report: MeterReport) { reports.withLock { $0.append(report) } }
        var all: [MeterReport] { reports.withLock { $0 } }
    }

    private func makeMeter(counting: Bool = false) -> (ChannelMeter, Collector) {
        let collector = Collector()
        let tap = DiagnosticsTap(sessionStart: start) { collector.add($0) }
        return (ChannelMeter(channelID: channel, tap: tap, countsUtterances: counting), collector)
    }

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func sine(_ count: Int, rate: Double, amplitude: Float = 0.1, from index: Int = 0) -> [Float] {
        (0..<count).map { amplitude * sin(Float(index + $0) * 2 * .pi * 1000 / Float(rate)) }
    }

    /// Feeds `seconds` of audio in 100 ms blocks, starting at session time `from`.
    private func feed(
        _ meter: inout ChannelMeter, seconds: Double, from: Double, rate: Double = 48_000,
        block: ([Float]) -> [Float] = { $0 }, dropped: Int = 0
    ) {
        let blockCount = Int((seconds * 10).rounded())
        let size = Int(rate / 10)
        for i in 0..<blockCount {
            let samples = block(sine(size, rate: rate, from: i * size))
            meter.add(samples, sampleRate: rate, droppedFrames: dropped, at: at(from + Double(i) / 10))
        }
    }

    @Test func toneMinuteHasLevelsAndAClip() throws {
        var (meter, collector) = makeMeter()
        feed(&meter, seconds: 61, from: 0)
        let first = try #require(collector.all.first)
        #expect(first.row.minute == 0)
        #expect(first.row.partial == true)
        #expect(abs(first.row.audio - 60) < 0.2)
        #expect(abs(first.row.sound - 60) < 0.2)
        #expect(abs(try #require(first.row.rms) - -23) < 0.5)
        #expect(abs(try #require(first.row.peak) - -20) < 0.1)
        #expect(first.row.clipped == 0)
        #expect(first.clip?.samples.count == 144_000)
        #expect(first.clip?.sampleRate == 48_000)
    }

    @Test func silenceHasNoLevelsAndNoClip() throws {
        var (meter, collector) = makeMeter()
        feed(&meter, seconds: 61, from: 0, block: { [Float](repeating: 0, count: $0.count) })
        let first = try #require(collector.all.first)
        #expect(first.row.rms == nil)
        #expect(first.row.peak == nil)
        #expect(first.row.floor == nil)
        #expect(first.row.sound == 0)
        #expect(first.clip == nil)
    }

    @Test func clippedSamplesCounted() throws {
        var (meter, collector) = makeMeter()
        var block = [Float](repeating: 0.01, count: 4_800)
        for i in 0..<10 { block[i * 10] = 1.0 }
        meter.add(block, sampleRate: 48_000, droppedFrames: 0, at: at(1))
        meter.finish(at: at(2))
        #expect(collector.all.first?.row.clipped == 10)
    }

    @Test func partialFrameTailIsNotCountedTwice() {
        var (meter, collector) = makeMeter()
        var block = [Float](repeating: 0.01, count: 1_000)
        block[990] = 1.0
        meter.add(block, sampleRate: 48_000, droppedFrames: 0, at: at(1))
        meter.add([Float](repeating: 0.01, count: 1_000), sampleRate: 48_000, droppedFrames: 0, at: at(1.1))
        meter.finish(at: at(2))
        #expect(collector.all.first?.row.clipped == 1)
    }

    @Test func floorIgnoresDigitalSilence() throws {
        var (meter, collector) = makeMeter()
        let rate = 48_000.0
        // Half zeros, half hiss at about -60 dBFS (rms 0.001).
        let hiss = (0..<Int(rate)).map { Float($0 % 2 == 0 ? 0.001 : -0.001) }
        meter.add([Float](repeating: 0, count: Int(rate)), sampleRate: rate, droppedFrames: 0, at: at(1))
        meter.add(hiss, sampleRate: rate, droppedFrames: 0, at: at(2))
        meter.finish(at: at(3))
        let floor = try #require(collector.all.first?.row.floor)
        #expect(abs(floor - -60) < 1)
    }

    @Test func rateChangeInsideAMinuteRestartsTheClip() throws {
        var (meter, collector) = makeMeter()
        let quiet = [Float](repeating: 0, count: 4_800)
        for i in 0..<100 { meter.add(quiet, sampleRate: 48_000, droppedFrames: 0, at: at(Double(i) / 10)) }
        feed(&meter, seconds: 1, from: 10, rate: 48_000)
        feed(&meter, seconds: 5, from: 11, rate: 44_100)
        meter.finish(at: at(20))
        let clip = try #require(collector.all.first?.clip)
        #expect(clip.sampleRate == 44_100)
        #expect(clip.samples.count == 132_300)
    }

    @Test func droppedFramesAreTheMinutesDifference() throws {
        var (meter, collector) = makeMeter()
        let block = sine(4_800, rate: 48_000)
        meter.add(block, sampleRate: 48_000, droppedFrames: 0, at: at(1))
        meter.add(block, sampleRate: 48_000, droppedFrames: 4_800, at: at(30))
        meter.add(block, sampleRate: 48_000, droppedFrames: 9_600, at: at(65))
        meter.finish(at: at(66))
        let rows = collector.all.map(\.row)
        #expect(rows.count == 2)
        #expect(rows[0].dropped == 4_800)
        #expect(abs(rows[0].droppedSeconds - 0.1) < 1e-9)
        #expect(rows[1].minute == 1)
        #expect(rows[1].dropped == 4_800)
    }

    @Test func emptyReadsStillCloseTheMinute() {
        var (meter, collector) = makeMeter()
        meter.add([], sampleRate: 48_000, droppedFrames: 0, at: at(10))
        meter.add([], sampleRate: 48_000, droppedFrames: 0, at: at(70))
        #expect(collector.all.count == 1)
        #expect(collector.all.first?.row.minute == 0)
        #expect(collector.all.first?.row.audio == 0)
    }

    @Test func rateChangeCountsSecondsPerBlock() throws {
        var (meter, collector) = makeMeter()
        feed(&meter, seconds: 30, from: 0, rate: 48_000)
        feed(&meter, seconds: 30, from: 30, rate: 44_100)
        meter.finish(at: at(61))
        let row = try #require(collector.all.first?.row)
        #expect(abs(row.audio - 60) < 0.2)
    }

    @Test func rateChangeRestartsTheClip() throws {
        var (meter, collector) = makeMeter()
        let quietBlock = [Float](repeating: 0, count: 4_800)
        for i in 0..<590 { meter.add(quietBlock, sampleRate: 48_000, droppedFrames: 0, at: at(Double(i) / 10)) }
        feed(&meter, seconds: 0.5, from: 59, rate: 48_000)
        feed(&meter, seconds: 5, from: 59.5, rate: 44_100)
        feed(&meter, seconds: 4, from: 64.5, rate: 44_100)
        meter.finish(at: at(70))
        let reports = collector.all
        #expect(reports.count == 2)
        #expect(reports[0].row.minute == 0)
        #expect(reports[0].clip == nil)
        #expect(reports[1].row.minute == 1)
        #expect(reports[1].clip?.sampleRate == 44_100)
        #expect(reports[1].clip?.samples.count == 132_300)
    }

    @Test func utteranceCountsOnlyWhenCounting() throws {
        var (counting, countedReports) = makeMeter(counting: true)
        counting.add([0.1], sampleRate: 48_000, droppedFrames: 0, at: at(1))
        counting.recognized(modelSeconds: 1.2, audioSeconds: 20, cut: true)
        counting.finish(at: at(2))
        let row = try #require(countedReports.all.first?.row)
        #expect(row.utterances == 1)
        #expect(row.speech == 20)
        #expect(row.cuts == 1)
        #expect(row.recognize == 1.2)

        var (plain, plainReports) = makeMeter(counting: false)
        plain.add([0.1], sampleRate: 48_000, droppedFrames: 0, at: at(1))
        plain.recognized(modelSeconds: 1.2, audioSeconds: 20, cut: true)
        plain.finish(at: at(2))
        let other = try #require(plainReports.all.first?.row)
        #expect(other.utterances == nil && other.speech == nil && other.cuts == nil && other.recognize == nil)
    }

    @Test func countingMeterReportsZerosWhenNothingRecognised() throws {
        var (meter, collector) = makeMeter(counting: true)
        meter.add([0.1], sampleRate: 48_000, droppedFrames: 0, at: at(1))
        meter.finish(at: at(2))
        let row = try #require(collector.all.first?.row)
        #expect(row.utterances == 0 && row.speech == 0 && row.cuts == 0 && row.recognize == 0)
    }

    @Test func finishEmitsPartialMinute() throws {
        var (meter, collector) = makeMeter()
        feed(&meter, seconds: 10, from: 0)
        meter.finish(at: at(10))
        let row = try #require(collector.all.first?.row)
        #expect(row.partial == true)
        #expect(abs(row.audio - 10) < 0.2)
    }
}
