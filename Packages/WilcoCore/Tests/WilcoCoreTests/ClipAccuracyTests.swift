import Foundation
import Testing
@testable import WilcoCore

@Suite("Clip accuracy")
struct ClipAccuracyTests {
    let channel = ChannelConfig(name: "Band TB")
    var show: ShowDocument { ShowDocument(name: "Show", channels: [channel]) }

    func line(_ text: String, at offset: Double, on id: UUID? = nil, final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(channelID: id ?? channel.id, text: text, timestamp: Date(timeIntervalSince1970: 1_000 + offset),
                          sessionOffset: offset, isFinal: final)
    }

    /// `count` clips, each answered "go cue five", whose live text is `live`.
    func session(count: Int, live: String) -> (segments: [TranscriptSegment], clips: SessionClips) {
        var segments: [TranscriptSegment] = []
        var manifest = ClipManifest()
        var labels = ClipLabels()
        for i in 0..<count {
            let at = Double(i) * 20
            segments.append(line(live, at: at))
            let clip = ClipRecord(channel: channel.id, kind: .unclear, sessionOffset: at, duration: 3, engine: "apple")
            manifest.clips.append(clip)
            labels.clips.append(ClipLabel(clip: clip.id, words: .agreed, text: "go cue five"))
        }
        return (segments, SessionClips(manifest: manifest, labels: labels))
    }

    func review(_ s: (segments: [TranscriptSegment], clips: SessionClips), history: [SessionSummary] = []) -> ShowReview {
        ShowReview.make(segments: s.segments, show: show, history: history, clips: s.clips)
    }

    @Test func liveTextJoinsLinesInsideTheClip() {
        let other = UUID()
        let segments = [line("one", at: 9.6), line("two", at: 10), line("three", at: 12.5),
                        line("late", at: 13.5), line("elsewhere", at: 10, on: other), line("partial", at: 11, final: false)]
        let clip = ClipRecord(channel: channel.id, kind: .unclear, sessionOffset: 10, duration: 3, engine: "apple")
        #expect(ClipAccuracy.liveText(for: clip, in: segments) == "one two three")
    }

    @Test func backToBackClipsDoNotShareLines() {
        let segments = [line("first", at: 10), line("split piece", at: 11.5), line("noise edge", at: 12.95), line("next", at: 13)]
        let a = ClipRecord(channel: channel.id, kind: .exchange, sessionOffset: 10, duration: 3, engine: "apple")
        #expect(ClipAccuracy.liveText(for: a, in: segments) == "first split piece")
        let b = ClipRecord(channel: channel.id, kind: .exchange, sessionOffset: 13, duration: 3, engine: "apple")
        #expect(ClipAccuracy.liveText(for: b, in: [line("next", at: 13)]) == "next")
    }

    @Test func perChannelScoresOnlyAnsweredClips() {
        let clips = (0..<3).map { ClipRecord(channel: channel.id, kind: .unclear, sessionOffset: Double($0) * 20, duration: 3, engine: "apple") }
        let labels = ClipLabels(clips: [
            ClipLabel(clip: clips[0].id, words: .agreed, text: "go cue five"),
            ClipLabel(clip: clips[1].id, words: .disputed),
            ClipLabel(clip: clips[2].id, words: .checked, checked: "hold please"),
        ])
        let segments = [line("go cue five", at: 0), line("hold please", at: 20), line("hole please", at: 40)]
        let result = ClipAccuracy.perChannel(segments: segments, clips: SessionClips(manifest: ClipManifest(clips: clips), labels: labels))
        #expect(result[channel.id]?.clips == 2)
        let expected = WordErrorRate.compare(reference: ["go", "cue", "five"], hypothesis: ["go", "cue", "five"])
            + WordErrorRate.compare(reference: ["hold", "please"], hypothesis: ["hole", "please"])
        #expect(result[channel.id]?.errors == expected)
        #expect(expected.errors == 1)
    }

    @Test func accuracyFindingNeedsTenClips() {
        let nine = review(session(count: 9, live: "go cue five"))
        #expect(!nine.findings.contains { $0.id == "accuracy" })
        let ten = review(session(count: 10, live: "go cue fine"))
        let finding = ten.findings.first { $0.id == "accuracy" }
        #expect(finding?.detail.contains("% of words wrong on 10 clips") == true)
        #expect(finding?.detail.contains("Band TB: 33% of words wrong") == true)
        #expect(finding?.severity == .info)
        #expect(finding?.fixes.isEmpty == true)
    }

    @Test func accuracyShowsLastShow() {
        var earlier = SessionSummary(id: URL(fileURLWithPath: "/tmp/a.jsonl"), started: Date(timeIntervalSince1970: 0),
                                     showName: "Show", lines: 100, fillerShare: 0, unclearShare: 0, delayP90: nil)
        earlier.clipErrors[channel.id] = WordErrors(substitutions: 2, referenceWords: 10)
        earlier.clipCounts[channel.id] = 10
        var thin = earlier
        thin.clipCounts[channel.id] = 4
        let result = review(session(count: 10, live: "go cue fine"), history: [thin, earlier])
        #expect(result.findings.first { $0.id == "accuracy" }?.detail.contains("(was 20% last show)") == true)
    }

    @Test func olderSessionsWithoutClipsStillReview() {
        let s = session(count: 12, live: "go cue five")
        let plain = ShowReview.make(segments: s.segments, show: show)
        let withNil = ShowReview.make(segments: s.segments, show: show, clips: nil)
        #expect(plain.findings.map(\.id) == withNil.findings.map(\.id))
        #expect(!plain.findings.contains { $0.id == "accuracy" })
    }

    @Test func summaryCarriesClipErrors() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = session(count: 10, live: "go cue fine")
        let url = dir.appendingPathComponent("Session 2026-11-20 1900-00.jsonl")
        var data = Data()
        for seg in s.segments { data.append(try TranscriptFile.line(for: seg)) }
        try data.write(to: url)
        let folder = ClipsFolder.url(forTranscript: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ClipsFolder.save(s.clips.manifest, in: folder)
        try ClipsFolder.save(s.clips.labels, in: folder)
        let summary = try SessionHistory.summary(transcript: url, candidates: [show])
        #expect(summary.clipCounts[channel.id] == 10)
        #expect(summary.clipErrorRate.map { abs($0 - 1.0 / 3) < 0.001 } == true)
    }
}

extension ClipAccuracyTests {
    @Test func reviewReportsSessionClipErrorRate() {
        let s = session(count: 3, live: "go cue fine")
        #expect(abs((review(s).clipErrorRate ?? 0) - 1.0 / 3) < 0.001)
        #expect(ShowReview.make(segments: s.segments, show: show).clipErrorRate == nil)
    }
}
