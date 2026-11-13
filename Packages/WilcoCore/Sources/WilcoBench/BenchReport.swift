import Foundation

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
    /// Seconds from the end of a call to its final line.
    public var finalLatency: LatencySummary?
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

    public struct Sample: Codable, Equatable, Sendable {
        public var reference: String
        public var hypothesis: String
    }

    public var wordErrorRate: Double { wordErrors.rate }

    /// The engine kept pace: nothing failed or was dropped, almost every call
    /// got a line, and lines came within a few seconds even at the slow end.
    public var keepsUp: Bool {
        failures.isEmpty
            && droppedFrames == 0
            && Double(missed) <= Double(utterances) * 0.05
            && (finalLatency?.p95 ?? .infinity) <= Self.acceptableDelay
            && drainSeconds <= Self.acceptableDelay
    }

    /// A call's line should be on screen within this many seconds of it ending.
    public static let acceptableDelay = 3.0
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

    public static let tableHeader = """
        | Engine | Ch | WER | Missed | Final delay p50 / p95 / max | First words p50 | Backlog | Start | CPU (us) | CPU (Mac) | Memory | Dropped | Keeps up |
        |---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|:---:|
        """

    public static func tableRow(_ r: RunResult) -> String {
        func s(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "–" }
        let delay = r.finalLatency.map { String(format: "%.2f / %.2f / %.2f s", $0.p50, $0.p95, $0.max) } ?? "–"
        let cells = [
            r.engine,
            "\(r.channels)",
            String(format: "%.1f%%", r.wordErrorRate * 100),
            "\(r.missed)/\(r.utterances)",
            delay,
            s(r.firstWordLatency?.p50),
            s(r.drainSeconds),
            s(r.startSeconds),
            String(format: "%.0f%%", r.processCPU * 100),
            String(format: "%.0f%%", r.systemCPU * 100),
            String(format: "%.0f MB", r.peakMemoryMB),
            "\(r.droppedFrames)",
            r.keepsUp ? "yes" : "**no**",
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    public func markdown() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# Wilco transcription benchmark",
            "",
            "\(formatter.string(from: date)) · \(machine) · macOS \(osVersion) · speech: \(corpus)"
                + (idleSystemCPU.map { String(format: " · Mac idle: %.0f%% CPU", $0 * 100) } ?? ""),
            "",
            Self.tableHeader,
        ]
        lines += results.map(Self.tableRow)
        lines += [
            "",
            "WER: word error rate over each channel's whole transcript. Final delay: end of a call to its final line. "
                + "Backlog: how long after the audio stopped the last line arrived. CPU (us): cores this process used "
                + "(100% = one core). CPU (Mac): share of all cores busy. Keeps up: no failures or dropped audio, "
                + "≤ 5% of calls missed, p95 delay and backlog ≤ \(Int(RunResult.acceptableDelay)) s.",
        ]
        let failed = results.filter { !$0.failures.isEmpty }
        if !failed.isEmpty {
            lines += ["", "## Failures", ""]
            lines += failed.map { "- \($0.engine) × \($0.channels): " + $0.failures.prefix(3).joined(separator: "; ") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
