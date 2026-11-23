import Foundation
import Synchronization
import Testing
@testable import WilcoCore

/// Deterministic generator for reservoir tests (SplitMix64).
private final class SeededRandom: Sendable {
    private let state: Mutex<UInt64>
    init(seed: UInt64) { state = Mutex(seed) }
    func next(_ n: Int) -> Int {
        state.withLock { s in
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z % UInt64(n))
        }
    }
}

@Suite struct ClipSelectorTests {
    private func line(
        _ channel: UUID, at offset: Double, duration: Double = 2, confidence: Double? = 0.95
    ) -> ClipCandidate {
        ClipCandidate(id: UUID(), channel: channel, sessionOffset: offset, duration: duration, confidence: confidence)
    }

    private func keeps(_ changes: [ClipChange]) -> [ClipChange] {
        changes.filter { if case .keep = $0 { true } else { false } }
    }

    /// Offers `count` lines 30 s apart (no runs) and returns the offset after the last one.
    @discardableResult
    private func warmUp(
        _ selector: inout ClipSelector, channel: UUID, count: Int = 20, confidence: Double = 0.9, from start: Double = 0
    ) -> Double {
        var offset = start
        for _ in 0..<count {
            _ = selector.offer(line(channel, at: offset, confidence: confidence))
            offset += 30
        }
        return offset
    }

    @Test func keepsLowConfidenceAfterWarmup() {
        var selector = ClipSelector()
        let channel = UUID()
        var offset = 0.0
        for _ in 0..<20 {
            #expect(keeps(selector.offer(line(channel, at: offset, confidence: 0.9))).isEmpty)
            offset += 30
        }
        let low = line(channel, at: offset, confidence: 0.5)
        #expect(keeps(selector.offer(low)) == [.keep(low.id, .unclear, exchange: nil)])
        #expect(keeps(selector.offer(line(channel, at: offset + 30, confidence: 0.95))).isEmpty)
    }

    @Test func warmupUsesFixedThreshold() {
        var selector = ClipSelector()
        let first = line(UUID(), at: 0, confidence: 0.7)
        #expect(keeps(selector.offer(first)) == [.keep(first.id, .unclear, exchange: nil)])
        #expect(keeps(selector.offer(line(UUID(), at: 0, confidence: 0.8))).isEmpty)
    }

    @Test func nilConfidenceIsUnclear() {
        var selector = ClipSelector()
        let unknown = line(UUID(), at: 0, confidence: nil)
        #expect(keeps(selector.offer(unknown)) == [.keep(unknown.id, .unclear, exchange: nil)])
    }

    @Test func channelsAreJudgedSeparately() {
        var selector = ClipSelector()
        let a = UUID(), b = UUID()
        let endA = warmUp(&selector, channel: a, confidence: 0.6)
        let endB = warmUp(&selector, channel: b, confidence: 0.95)
        #expect(keeps(selector.offer(line(a, at: endA, confidence: 0.7))).isEmpty)
        let onB = line(b, at: endB, confidence: 0.9)
        #expect(keeps(selector.offer(onB)) == [.keep(onB.id, .unclear, exchange: nil)])
    }

    @Test func skipsEmptyAndOutOfRangeAudio() {
        var selector = ClipSelector()
        let channel = UUID()
        let first = line(channel, at: 0)
        #expect(selector.offer(first) == [.hold(first.id)])
        #expect(selector.offer(line(channel, at: 2.5), samplesEmpty: true) == [])
        #expect(selector.offer(line(channel, at: 3, duration: 0.4)) == [])
        #expect(selector.offer(line(channel, at: 4, duration: 19.5)) == [])
        // Nearby, but the skipped lines broke the run: the first line's run closes alone.
        let second = line(channel, at: 5)
        #expect(selector.offer(second) == [.remove(first.id), .hold(second.id)])
        let third = line(channel, at: 8), fourth = line(channel, at: 11)
        _ = selector.offer(third)
        _ = selector.offer(fourth)
        #expect(selector.finish() == [second, third, fourth].map { .keep($0.id, .exchange, exchange: 1) })
    }

    @Test func skippedLinesDontCountTowardThePercentile() {
        var selector = ClipSelector()
        let channel = UUID()
        let end = warmUp(&selector, channel: channel, confidence: 0.9)
        for i in 0..<20 {
            _ = selector.offer(line(channel, at: end + Double(i) * 30, confidence: 0.1), samplesEmpty: true)
        }
        let probe = line(channel, at: end + 1000, confidence: 0.85)
        #expect(keeps(selector.offer(probe)) == [.keep(probe.id, .unclear, exchange: nil)])
    }

    @Test func threeCloseLinesMakeAnExchange() {
        var selector = ClipSelector()
        let channel = UUID()
        let end = warmUp(&selector, channel: channel, confidence: 0.9)
        let start = end + 100
        let run = [0.0, 4, 8].map { line(channel, at: start + $0, confidence: 0.95) }
        #expect(selector.offer(run[0]).last == .hold(run[0].id))
        #expect(selector.offer(run[1]) == [.hold(run[1].id)])
        #expect(selector.offer(run[2]) == [.hold(run[2].id)])
        let far = line(channel, at: start + 100, confidence: 0.95)
        #expect(selector.offer(far) == run.map { .keep($0.id, .exchange, exchange: 1) } + [.hold(far.id)])
    }

    @Test func twoLinesAreNotAnExchange() {
        var selector = ClipSelector()
        let channel = UUID()
        let pair = [line(channel, at: 0), line(channel, at: 4)]
        _ = selector.offer(pair[0])
        _ = selector.offer(pair[1])
        let far = line(channel, at: 100)
        #expect(selector.offer(far) == pair.map { .remove($0.id) } + [.hold(far.id)])
    }

    @Test func runClosesAtTwelveLines() {
        var selector = ClipSelector()
        let channel = UUID()
        let run = (0..<12).map { line(channel, at: Double($0) * 4) }
        for l in run.dropLast() { #expect(selector.offer(l) == [.hold(l.id)]) }
        #expect(selector.offer(run[11]) == run.map { .keep($0.id, .exchange, exchange: 1) })
        // The next close line starts a fresh run.
        let next = line(channel, at: 48)
        #expect(selector.offer(next) == [.hold(next.id)])
    }

    @Test func linesOnOtherChannelsDontBreakARun() {
        var selector = ClipSelector()
        let a = UUID(), b = UUID()
        let run = [line(a, at: 0), line(a, at: 4), line(a, at: 8)]
        _ = selector.offer(run[0])
        _ = selector.offer(line(b, at: 2))
        _ = selector.offer(run[1])
        _ = selector.offer(line(b, at: 300))
        _ = selector.offer(run[2])
        let changes = selector.finish()
        #expect(keeps(changes) == run.map { .keep($0.id, .exchange, exchange: 1) })
    }

    @Test func exchangeTakesOverUnclearLines() {
        // Never replaces once full, so a later unclear line fits only in a freed slot.
        var selector = ClipSelector(unclearCap: 1, random: { $0 - 1 })
        let channel = UUID()
        let unclear = line(channel, at: 0, confidence: 0.5)
        #expect(selector.offer(unclear) == [.keep(unclear.id, .unclear, exchange: nil), .hold(unclear.id)])
        let second = line(channel, at: 4), third = line(channel, at: 8)
        _ = selector.offer(second)
        _ = selector.offer(third)
        let later = line(channel, at: 100, confidence: 0.5)
        let changes = selector.offer(later)
        #expect(changes == [
            .keep(unclear.id, .exchange, exchange: 1), .keep(second.id, .exchange, exchange: 1),
            .keep(third.id, .exchange, exchange: 1), .keep(later.id, .unclear, exchange: nil), .hold(later.id),
        ])
        #expect(!changes.contains(.remove(unclear.id)))
    }

    @Test func unclearLineInARunThatIsntKeptStaysKept() {
        var selector = ClipSelector()
        let channel = UUID()
        let unclear = line(channel, at: 0, confidence: 0.5), plain = line(channel, at: 4)
        _ = selector.offer(unclear)
        _ = selector.offer(plain)
        let far = line(channel, at: 100)
        #expect(selector.offer(far) == [.remove(plain.id), .hold(far.id)])
    }

    @Test func evictionOfAHeldLineWaitsForItsRun() {
        // Cap 1, and every later unclear line replaces slot 0.
        var selector = ClipSelector(unclearCap: 1, random: { _ in 0 })
        let channel = UUID(), other = UUID()
        let held = line(channel, at: 0, confidence: 0.5)
        _ = selector.offer(held)
        let replacement = line(other, at: 1, confidence: 0.5)
        // Still held by its open run, so no removal yet.
        #expect(selector.offer(replacement) == [.keep(replacement.id, .unclear, exchange: nil), .hold(replacement.id)])
        let far = line(channel, at: 100)
        #expect(selector.offer(far) == [.remove(held.id), .hold(far.id)])
    }

    @Test func exchangeReservoirReplacesWholeExchanges() {
        var selector = ClipSelector(exchangeCap: 1, random: { _ in 0 })
        let channel = UUID()
        let first = (0..<3).map { line(channel, at: Double($0) * 4) }
        let second = (0..<3).map { line(channel, at: 100 + Double($0) * 4) }
        for l in first { _ = selector.offer(l) }
        for l in second { _ = selector.offer(l) }
        #expect(selector.finish() == first.map { .remove($0.id) } + second.map { .keep($0.id, .exchange, exchange: 2) })
    }

    @Test func reservoirSpreadsOverTheSession() {
        let generator = SeededRandom(seed: 42)
        var selector = ClipSelector(unclearCap: 10, random: { generator.next($0) })
        let channel = UUID()
        var kept: [UUID: Double] = [:]
        var held: Set<UUID> = []
        var offsets: [UUID: Double] = [:]
        var badRemovals = 0
        func apply(_ changes: [ClipChange]) {
            for change in changes {
                switch change {
                case .keep(let id, _, _): kept[id] = offsets[id]
                case .remove(let id):
                    // Every removal names audio the keeper has: kept, or held for an open run.
                    let wasKept = kept.removeValue(forKey: id) != nil
                    if !wasKept && held.remove(id) == nil { badRemovals += 1 }
                case .hold(let id): held.insert(id)
                }
            }
        }
        for i in 0..<1000 {
            let l = line(channel, at: Double(i) * 30, confidence: nil)
            offsets[l.id] = l.sessionOffset
            apply(selector.offer(l))
        }
        apply(selector.finish())
        #expect(kept.count == 10)
        #expect(kept.values.filter { $0 > 500 * 30 }.count >= 5)
        #expect(badRemovals == 0)
    }

    @Test func rejectedTwelveLineRunDoesntRemoveItsUnheldLastLine() {
        var selector = ClipSelector(exchangeCap: 1, random: { $0 - 1 })
        let channel = UUID()
        let first = (0..<12).map { line(channel, at: Double($0) * 4, confidence: 0.95) }
        let second = (0..<12).map { line(channel, at: 200 + Double($0) * 4, confidence: 0.95) }
        for l in first { _ = selector.offer(l) }
        for l in second.dropLast() { _ = selector.offer(l) }
        // The reservoir rejects the second run; its 12th line was never held, so it isn't removed.
        #expect(selector.offer(second[11]) == second.dropLast().map { .remove($0.id) })
    }

    @Test func everyRemovalNamesAudioTheKeeperHas() {
        let generator = SeededRandom(seed: 7)
        let choices = SeededRandom(seed: 99)
        var selector = ClipSelector(unclearCap: 3, exchangeCap: 2, random: { generator.next($0) })
        let channelIDs = (0..<4).map { _ in UUID() }
        var offsets = [Double](repeating: 0, count: channelIDs.count)
        var held: Set<UUID> = [], kept: Set<UUID> = [], removed: Set<UUID> = []
        var problems: [String] = []
        func apply(_ changes: [ClipChange]) {
            for change in changes {
                switch change {
                case .hold(let id): held.insert(id)
                case .keep(let id, _, _):
                    if removed.contains(id) { problems.append("keep after remove") }
                    kept.insert(id)
                case .remove(let id):
                    if removed.contains(id) { problems.append("removed twice") }
                    if !held.contains(id) && !kept.contains(id) { problems.append("remove of unknown id") }
                    removed.insert(id)
                    kept.remove(id)
                }
            }
        }
        for _ in 0..<5000 {
            let c = choices.next(channelIDs.count)
            // Mostly close lines (runs), sometimes a long gap.
            offsets[c] += choices.next(10) == 0 ? 60 : Double(choices.next(12)) + 2
            let roll = choices.next(20)
            let duration = roll == 0 ? 0.3 : (roll == 1 ? 25 : 2)
            let confidence: Double? = roll == 2 ? nil : 0.5 + Double(choices.next(50)) / 100
            let l = line(channelIDs[c], at: offsets[c], duration: duration, confidence: confidence)
            apply(selector.offer(l, samplesEmpty: roll == 3))
        }
        apply(selector.finish())
        #expect(problems.isEmpty, "\(Set(problems))")
        #expect(held.subtracting(kept).subtracting(removed).isEmpty)
        #expect(kept.isDisjoint(with: removed))
        #expect(!kept.isEmpty && !removed.isEmpty)
    }

    @Test func finishClosesOpenRuns() {
        var selector = ClipSelector()
        let channel = UUID()
        let run = [line(channel, at: 0), line(channel, at: 4), line(channel, at: 8)]
        for l in run { _ = selector.offer(l) }
        #expect(selector.finish() == run.map { .keep($0.id, .exchange, exchange: 1) })
        #expect(selector.finish() == [])
    }
}
