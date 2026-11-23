import Foundation
import WilcoCore

/// One engine at one channel count.
public struct RunResult: Codable, Equatable, Sendable {
    public var engine: String
    public var channels: Int
    public var duration: Double
    public var dutyCycle: Double
    /// Speech played across all channels, in seconds.
    public var speechSeconds: Double
    public var utterances: Int
    /// Calls no final line was attributed to.
    public var missed: Int
    public var wordErrors: WordErrors
    /// Seconds from the end of a call to its final line (when rules can act on it).
    public var finalLatency: LatencySummary?
    /// Seconds from the end of a call to its line on screen, after voice
    /// analysis. Matches `finalLatency` when lines aren't annotated.
    public var displayLatency: LatencySummary?
    /// Seconds from the start of a call to the first words on screen.
    public var firstWordLatency: LatencySummary?
    /// Time for every channel to be listening (includes loading the model).
    public var startSeconds: Double
    /// How long after the audio stopped the last line arrived.
    public var drainSeconds: Double
    /// Audio lost because a transcriber didn't read its ring in time.
    public var droppedFrames: Int
    /// Average cores this process used.
    public var processCPU: Double
    /// Average share of all cores busy, including other processes.
    public var systemCPU: Double
    public var peakMemoryMB: Double
    public var failures: [String]
    /// The first channels' full reference and transcript, for a look by eye.
    public var samples: [Sample] = []
    /// How long after the audio stopped the last line reached the screen
    /// (after voice analysis). Nil in reports from before voice changes.
    public var displayBacklog: Double?
    /// Voice-change scores, for engines that detect voice changes.
    public var voices: VoiceScore?
    /// The voice-change threshold the run used, for those engines.
    public var voiceThreshold: Double?
    /// Conversation turns answered by the previous turn's line in the same
    /// exchange (final only after they ended). Not counted as missed.
    public var merged: Int?
    /// True for long-talk runs, which are also judged on words lost. Nil for
    /// other runs and in reports from before long talks.
    public var longTalk: Bool?
    /// Diagnostics clips the sound classifier's queue dropped because it was
    /// full. Nil when the run had no diagnostics (and in older reports).
    public var droppedClips: Int?
    /// Rows the run's diagnostics file held after the run, and how many of
    /// them carry a sound classification. Nil without diagnostics.
    public var diagnosticsRows: Int?
    public var classifiedRows: Int?

    public struct Sample: Codable, Equatable, Sendable {
        public var reference: String
        public var hypothesis: String
    }

    public var wordErrorRate: Double { wordErrors.rate }

    /// Share of the spoken words with nothing in the transcript where they
    /// belong. Wrong words don't count, only missing ones: it's what a
    /// segmenter that stops listening partway through a talk looks like.
    public var wordsLost: Double {
        wordErrors.referenceWords > 0 ? Double(wordErrors.deletions) / Double(wordErrors.referenceWords) : 0
    }

    /// Cues kept pace: nothing failed or was dropped, almost every call got a
    /// final line, and final lines (when rules fire) came within a few
    /// seconds even at the slow end.
    public var cuesKeepUp: Bool {
        failures.isEmpty
            && droppedFrames == 0
            && Double(missed) <= Double(utterances) * 0.05
            && (finalLatency?.p95 ?? .infinity) <= Self.acceptableDelay
            && drainSeconds <= Self.acceptableDelay
            && (longTalk != true || wordsLost <= Self.acceptableWordsLost)
    }

    /// For engines that detect voice changes: lines reached the screen, with
    /// their letters, within a few seconds, and the display's backlog stayed
    /// as short. Nil for other engines.
    public var displayKeepsUp: Bool? {
        guard voices != nil else { return nil }
        return (displayLatency?.p95 ?? .infinity) <= Self.acceptableDelay
            && (displayBacklog ?? .infinity) <= Self.acceptableDelay
    }

    /// Cues keep up and, with voice changes on, so does the display.
    public var keepsUp: Bool { cuesKeepUp && displayKeepsUp != false }

    /// A call's line should be on screen within this many seconds of it ending.
    public static let acceptableDelay = 3.0
    /// A long-talk run may lose this share of its words and still pass.
    public static let acceptableWordsLost = 0.10
}

public struct BenchReport: Codable, Equatable, Sendable {
    public var date: Date
    public var machine: String
    public var osVersion: String
    /// Where the speech came from: "say" or a folder of recordings.
    public var corpus: String
    /// Share of all cores busy before any engine ran.
    public var idleSystemCPU: Double?
    public var results: [RunResult]

    public init(
        date: Date, machine: String, osVersion: String, corpus: String, idleSystemCPU: Double? = nil,
        results: [RunResult]
    ) {
        self.date = date
        self.machine = machine
        self.osVersion = osVersion
        self.corpus = corpus
        self.idleSystemCPU = idleSystemCPU
        self.results = results
    }

    public static let tableHeader = tableHeader(longTalk: false)

    /// Long-talk runs get a "Words lost" column after WER; runs with
    /// diagnostics get a "Clips dropped" column after Dropped.
    public static func tableHeader(longTalk: Bool, diagnostics: Bool = false) -> String {
        let lost = longTalk ? (" Words lost |", "---:|") : ("", "")
        let clips = diagnostics ? (" Clips dropped | Rows (classified) |", "---:|---:|") : ("", "")
        return """
            | Engine | Ch | WER |\(lost.0) Missed | Final delay p50 / p95 / max | Display p95 | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped |\(clips.0) Keeps up |
            |---|---:|---:|\(lost.1)---:|---|---:|---:|---:|---:|---:|---:|---:|---:|\(clips.1):---:|
            """
    }

    public static func tableRow(_ r: RunResult, diagnostics: Bool = false) -> String {
        func s(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "–" }
        let delay = r.finalLatency.map { String(format: "%.2f / %.2f / %.2f s", $0.p50, $0.p95, $0.max) } ?? "–"
        var cells: [String] = [
            r.engine,
            "\(r.channels)",
            String(format: "%.1f%%", r.wordErrorRate * 100),
        ]
        if r.longTalk == true { cells.append(String(format: "%.1f%%", r.wordsLost * 100)) }
        let merged = (r.merged ?? 0) > 0 ? " (\(r.merged ?? 0) merged)" : ""
        cells += [
            "\(r.missed)/\(r.utterances)" + merged,
            delay,
            s(r.displayLatency?.p95),
            s(r.firstWordLatency?.p50),
            s(r.drainSeconds),
            s(r.startSeconds),
            String(format: "%.0f%%", r.processCPU * 100),
            String(format: "%.0f%%", r.systemCPU * 100),
            String(format: "%.0f MB", r.peakMemoryMB),
            "\(r.droppedFrames)",
        ]
        if diagnostics {
            cells.append(r.droppedClips.map(String.init) ?? "–")
            cells.append(r.diagnosticsRows.map { "\($0) (\(r.classifiedRows ?? 0))" } ?? "–")
        }
        cells.append(r.keepsUp ? "yes" : "**no**")
        return "| " + cells.joined(separator: " | ") + " |"
    }

    public static let voiceTableHeader = """
        | Engine | Ch | Changes missed | False changes | Letters right | No letter | Not annotated | Merged calls | Final p95 | Display p50 / p95 | Display backlog | CPU added | Threshold | Keeps up (cues / display) |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|:---:|
        """

    /// One run's voice scores; `without` is the same engine at the same
    /// channel count with voice changes off, when the report has it.
    public static func voiceRow(_ r: RunResult, without base: RunResult? = nil) -> String {
        func s(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "–" }
        func yes(_ value: Bool?) -> String { value.map { $0 ? "yes" : "**no**" } ?? "–" }
        let v = r.voices ?? VoiceScore()
        let letters: String = v.letterAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
        let display: String = r.displayLatency.map { String(format: "%.2f / %.2f s", $0.p50, $0.p95) } ?? "–"
        let added: String = base.map { String(format: "%+.0f%%", (r.processCPU - $0.processCPU) * 100) } ?? "–"
        let threshold: String = r.voiceThreshold.map { String(format: "%.2f", $0) } ?? "–"
        let keeps: String = yes(r.cuesKeepUp) + " / " + yes(r.displayKeepsUp)
        let cells: [String] = [
            r.engine, "\(r.channels)", "\(v.missedChanges)/\(v.changes)", "\(v.falseChanges)", letters,
            "\(v.unlettered)/\(v.lines)", "\(v.missingAnnotations)", "\(r.merged ?? 0)", s(r.finalLatency?.p95), display,
            s(r.displayBacklog), added, threshold, keeps,
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    public func markdown() -> String {
        let formatter = ISO8601DateFormatter()
        let longTalk = results.contains { $0.longTalk == true }
        let diagnostics = results.contains { $0.droppedClips != nil }
        var lines = [
            "# Wilco transcription benchmark",
            "",
            "\(formatter.string(from: date)) · \(machine) · macOS \(osVersion) · speech: \(corpus)"
                + (idleSystemCPU.map { String(format: " · Mac idle: %.0f%% CPU", $0 * 100) } ?? ""),
            "",
            Self.tableHeader(longTalk: longTalk, diagnostics: diagnostics),
        ]
        lines += results.map { Self.tableRow($0, diagnostics: diagnostics) }
        let limit = Int(RunResult.acceptableDelay)
        lines += [
            "",
            "WER: word error rate over each channel's whole transcript. Missed: calls with no final line; "
                + "\"merged\" turns (conversations only) have no line of their own but are answered by the previous "
                + "turn's line in the same exchange, final only after they ended; that line's delay runs from the end "
                + "of the last turn in it. Final delay: end of a call to its final "
                + "line, when rules can act on it. Display: end of a call to its line on screen, after voice analysis. "
                + "Backlog: how long after the audio stopped the last final line arrived. CPU (us): cores this "
                + "process used (100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or "
                + "dropped audio, ≤ 5% of calls missed, p95 final delay and backlog ≤ \(limit) s; with voice changes "
                + "on, also display p95 and display backlog ≤ \(limit) s.",
        ]
        if diagnostics {
            lines += [
                "",
                "Clips dropped: sound clips the classifier's queue dropped because 64 were already waiting. Rows "
                    + "(classified): rows the run's diagnostics file held afterwards, and how many carry a "
                    + "classification; zero classified rows would make \"no clips dropped\" mean nothing. The run "
                    + "recorded session diagnostics (the per-minute meter and sound classifier) in every channel.",
            ]
        }
        if longTalk {
            lines += [
                "",
                "Words lost: spoken words with nothing in the transcript where they belong, as a share of all words "
                    + "spoken. Each call here is a long stretch of unbroken talking over hiss, and some drop to a "
                    + "quiet voice halfway. Keeps up also needs words lost ≤ "
                    + "\(Int(RunResult.acceptableWordsLost * 100))%.",
            ]
        }
        let voiced = results.filter { $0.voices != nil }
        if !voiced.isEmpty {
            lines += ["", "## Voice changes", "", Self.voiceTableHeader]
            lines += voiced.map { r in
                let base = r.engine.hasSuffix("-voices")
                    ? results.first { $0.engine == String(r.engine.dropLast(7)) && $0.channels == r.channels }
                    : nil
                return Self.voiceRow(r, without: base)
            }
            lines += [
                "",
                "Changes missed: turn boundaries where the voice changes (within an exchange) with no change of letter "
                    + "within ±0.5 s. False: changes of letter with no change of voice within ±0.5 s. Two turns the "
                    + "segmenter merged into one line count as a missed change unless the line was split there. "
                    + "Letters right: turns by a voice already heard in the exchange shown with its earlier "
                    + "letter. No letter: annotated lines without a letter (short or quiet lines, no voice model, or "
                    + "the channel's voice queue was full; these can't be told apart from outside). Not annotated: "
                    + "recognised lines whose annotation never arrived; each counts in the display delay at the "
                    + "moment the run stopped watching, a lower bound. Merged calls: turns that share an earlier "
                    + "turn's line. Display backlog: how long after the audio "
                    + "stopped the last line reached the screen. CPU added: this process's cores over the same "
                    + "engine without voice changes at the same channel count. Keeps up: cues / display, as above.",
            ]
        }
        let failed = results.filter { !$0.failures.isEmpty }
        if !failed.isEmpty {
            lines += ["", "## Failures", ""]
            lines += failed.map { "- \($0.engine) × \($0.channels): " + $0.failures.prefix(3).joined(separator: "; ") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
