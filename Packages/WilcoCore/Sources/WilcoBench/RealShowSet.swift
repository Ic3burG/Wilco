import Foundation
import WilcoCore

/// One exchange from a real show: its clips in the order they were said, and
/// the quiet between each one and the next.
public struct RealExchange: Equatable, Sendable {
    /// Indexes into `RealShowSet.clips`.
    public var clips: [Int]
    /// Seconds from each clip's end to the next one's start, capped at
    /// `RealShowSet.maximumGap`. One fewer than `clips`.
    public var gaps: [Double]

    public init(clips: [Int], gaps: [Double]) {
        self.clips = clips
        self.gaps = gaps
    }
}

/// The clips the app kept and labelled after real shows, as a benchmark
/// corpus. Only clips with an answer (agreed by the voters, or checked by
/// hand) are used.
///
/// Clips are real voices from real shows: nothing here that leaves the Mac
/// (terminal, reports) may hold their words. `summary` is numbers only.
public struct RealShowSet: Sendable {
    /// Answered clips, in session then manifest order. Each clip's voice is
    /// one number per (session, channel, speaker) when its voice was agreed,
    /// else a number of its own.
    public var clips: [BenchClip]
    /// Per clip: the voters whose own text has the same words as the answer.
    public var agreeingVoters: [Set<String>]
    /// Exchanges whose clips all have answers and agreed voices.
    public var exchanges: [RealExchange]
    /// What the live transcript said on the night, against the answers.
    public var live: WordErrors
    /// Sessions with labelled clips; usable clips agreed by the voters and
    /// checked by hand; labels without an answer; clips the keeper dropped
    /// because its queue was full, plus answered clips whose audio couldn't
    /// be read. `agreed + checked` is `clips.count`.
    public var counts: (sessions: Int, agreed: Int, checked: Int, disputed: Int, dropped: Int)

    /// Longest quiet kept between an exchange's clips. Longer pauses on the
    /// night (someone waiting on a reply) would only make runs slower.
    public static let maximumGap = 3.0

    public init(
        clips: [BenchClip], agreeingVoters: [Set<String>], exchanges: [RealExchange], live: WordErrors,
        counts: (sessions: Int, agreed: Int, checked: Int, disputed: Int, dropped: Int)
    ) {
        self.clips = clips
        self.agreeingVoters = agreeingVoters
        self.exchanges = exchanges
        self.live = live
        self.counts = counts
    }

    /// Counts only, for the terminal and the report's "speech" line.
    public var summary: String {
        "real show: \(counts.sessions) sessions, \(clips.count) clips (\(counts.agreed) agreed, "
            + "\(counts.checked) checked, \(counts.disputed) disputed, \(counts.dropped) dropped), "
            + "\(exchanges.count) exchanges"
    }

    /// The voter a bench engine is (the same model), if any: its scores on
    /// clips it helped label flatter it.
    public static func voter(forEngine id: String) -> String? {
        if id == "parakeet-ultra" || id.hasPrefix("parakeet-ultra-") { return ClipVoterID.parakeetUltra }
        if id == "apple-longform" || id.hasPrefix("apple-longform-") { return ClipVoterID.appleLongForm }
        if id == "whisper-large" || id.hasPrefix("whisper-large-") { return ClipVoterID.whisperLarge }
        return nil
    }

    /// Every `.jsonl` session in `transcripts` with a `.clips` folder holding
    /// a manifest and labels, oldest first by file name.
    public static func load(transcripts: URL, sampleRate: Double) throws -> RealShowSet {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        } catch {
            throw BenchError("Can't read the transcripts folder \(transcripts.path)")
        }
        let sessions = entries.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var clips: [BenchClip] = []
        var agreeing: [Set<String>] = []
        var exchanges: [RealExchange] = []
        var live = WordErrors()
        var counts = (sessions: 0, agreed: 0, checked: 0, disputed: 0, dropped: 0)
        var voiceNumbers: [String: Int] = [:]
        var nextVoice = 0
        func freshVoice() -> Int {
            defer { nextVoice += 1 }
            return nextVoice
        }

        for (sessionIndex, transcript) in sessions.enumerated() {
            guard let session = SessionClips.load(forTranscript: transcript) else { continue }
            counts.sessions += 1
            counts.dropped += session.manifest.dropped
            let folder = ClipsFolder.url(forTranscript: transcript)
            let segments = (try? Data(contentsOf: transcript)).map(TranscriptFile.segments(in:)) ?? []
            let labels = Dictionary(session.labels.clips.map { ($0.clip, $0) }, uniquingKeysWith: { first, _ in first })

            // Where each usable clip went in `clips`, and whether its voice was agreed.
            var placed: [UUID: (index: Int, voiceAgreed: Bool)] = [:]
            for record in session.manifest.clips {
                guard let label = labels[record.id] else { continue }
                guard let answer = label.answer else {
                    counts.disputed += 1
                    continue
                }
                // An answered clip whose audio can't be read counts only as dropped.
                guard let samples = try? audio(for: record, in: folder, sampleRate: sampleRate) else {
                    counts.dropped += 1
                    continue
                }
                // An answer is a hand check or the voters' agreed words.
                if label.checked != nil { counts.checked += 1 } else { counts.agreed += 1 }
                let voiceAgreed = label.voice == .agreed && label.speaker != nil
                let voice: Int
                if voiceAgreed, let speaker = label.speaker {
                    let key = "\(sessionIndex)|\(record.channel.uuidString)|\(speaker)"
                    if let known = voiceNumbers[key] {
                        voice = known
                    } else {
                        voice = freshVoice()
                        voiceNumbers[key] = voice
                    }
                } else {
                    voice = freshVoice()
                }
                let words = TranscriptNormalizer.words(answer)
                placed[record.id] = (clips.count, voiceAgreed)
                clips.append(BenchClip(text: answer, samples: samples, voice: voice))
                agreeing.append(Set(label.candidates.filter { !words.isEmpty && TranscriptNormalizer.words($0.value) == words }.keys))
                live = live + WordErrorRate.compare(
                    reference: words, hypothesis: TranscriptNormalizer.words(ClipAccuracy.liveText(for: record, in: segments))
                )
            }

            // Exchanges, kept whole only when every clip in them can be used with its voice.
            let grouped = Dictionary(grouping: session.manifest.clips.filter { $0.kind == .exchange && $0.exchange != nil }) {
                $0.exchange!
            }
            for number in grouped.keys.sorted() {
                let members = grouped[number]!.sorted { $0.sessionOffset < $1.sessionOffset }
                guard members.count >= 2,
                      members.allSatisfy({ placed[$0.id]?.voiceAgreed == true }) else { continue }
                let gaps = zip(members, members.dropFirst()).map { previous, next in
                    min(maximumGap, max(0, next.sessionOffset - (previous.sessionOffset + previous.duration)))
                }
                exchanges.append(RealExchange(clips: members.map { placed[$0.id]!.index }, gaps: gaps))
            }
        }
        return RealShowSet(clips: clips, agreeingVoters: agreeing, exchanges: exchanges, live: live, counts: counts)
    }

    private static func audio(for record: ClipRecord, in folder: URL, sampleRate: Double) throws -> [Float] {
        let decoded = try WAV.decode(try Data(contentsOf: ClipsFolder.audioURL(for: record.id, in: folder)))
        guard !decoded.samples.isEmpty, decoded.sampleRate > 0 else { throw BenchError("empty clip") }
        let rate = Double(decoded.sampleRate)
        return rate == sampleRate ? decoded.samples : try ClipLibrary.resample(decoded.samples, from: rate, to: sampleRate)
    }
}
