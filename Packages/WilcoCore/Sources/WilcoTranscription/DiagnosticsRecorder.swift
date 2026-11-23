import Foundation
import WilcoCore

/// Collects the finished minutes every channel's meter reports during one
/// capture session, adds the sound classifier's verdict, and writes them to
/// the session's `.diagnostics` file once each minute is old enough that its
/// classification has had time to arrive.
public actor DiagnosticsRecorder {
    private struct Key: Hashable {
        var channel: UUID
        var minute: Int
    }

    private let writer: DiagnosticsWriter
    private let sessionStart: Date
    private let classifier: SoundClassifierQueue?
    private let hold: Double
    private let now: @Sendable () -> Date
    private let continuation: AsyncStream<MeterReport>.Continuation
    private var stream: AsyncStream<MeterReport>?
    private var finished = false
    private var drainTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?

    private var rows: [Key: ChannelMinute] = [:]
    private var outstanding = 0
    private var writeFailed = false

    /// Where every channel's meter sends its minutes.
    public nonisolated let tap: DiagnosticsTap

    /// - Parameters:
    ///   - hold: Seconds past the end of a minute a row waits for its
    ///     classification before it is written without one.
    ///   - writeInterval: Seconds between automatic ``writeDue()`` passes;
    ///     nil starts no loop (tests call `writeDue()` themselves).
    public init(
        writer: sending DiagnosticsWriter, sessionStart: Date, classifier: SoundClassifierQueue?,
        hold: Double = 30, now: @escaping @Sendable () -> Date = Date.init,
        writeInterval: Double? = 5
    ) {
        self.writer = writer
        self.sessionStart = sessionStart
        self.classifier = classifier
        self.hold = hold
        self.now = now
        let (stream, continuation) = AsyncStream.makeStream(of: MeterReport.self)
        self.continuation = continuation
        self.tap = DiagnosticsTap(sessionStart: sessionStart) { continuation.yield($0) }
        self.stream = stream
        // The actor starts its own tasks once it exists.
        Task { await self.start(writeInterval: writeInterval) }
    }

    private func start(writeInterval: Double?) {
        guard !finished, let stream else { return }
        self.stream = nil
        drainTask = Task { [weak self] in
            for await report in stream {
                await self?.accept(report)
            }
        }
        if let writeInterval {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(writeInterval))
                    if Task.isCancelled { break }
                    await self?.writeDue()
                }
            }
        }
    }

    /// Writes, and forgets, every row whose minute ended more than `hold`
    /// seconds ago.
    public func writeDue() {
        let cutoff = now()
        let due = rows.filter { key, _ in
            sessionStart.addingTimeInterval(Double(key.minute + 1) * 60 + hold) <= cutoff
        }
        write(due.keys)
    }

    /// Stops the loop and drains the reports already sent, gives pending
    /// classifications up to `hold` seconds, then writes every row left.
    public func finish() async {
        loopTask?.cancel()
        continuation.finish()
        if !finished, let stream {
            // The drain never started; drain here.
            self.stream = nil
            for await report in stream { accept(report) }
        }
        finished = true
        await drainTask?.value
        let deadline = ContinuousClock.now + .seconds(hold)
        while outstanding > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        write(rows.keys)
    }

    /// Rows held back, waiting to be written. For tests.
    var heldRowCount: Int { rows.count }
    /// Classifications not yet answered. For tests.
    var pendingClassifications: Int { outstanding }

    private func accept(_ report: MeterReport) {
        let key = Key(channel: report.row.channel, minute: report.row.minute)
        if rows[key] != nil {
            rows[key]?.merge(report.row)
        } else {
            rows[key] = report.row
        }
        guard let clip = report.clip, let classifier else { return }
        outstanding += 1
        Task {
            let shares = await classifier.classify(clip)
            self.classified(shares, for: key)
        }
    }

    /// A late result, for a row already written, is dropped.
    private func classified(_ shares: SoundShares?, for key: Key) {
        outstanding -= 1
        guard let shares, rows[key] != nil, rows[key]?.classified == nil else { return }
        rows[key]?.classified = shares
    }

    private func write(_ keys: some Collection<Key>) {
        let ordered = keys.sorted {
            $0.minute != $1.minute ? $0.minute < $1.minute : $0.channel.uuidString < $1.channel.uuidString
        }
        for key in ordered {
            guard let row = rows.removeValue(forKey: key), !writeFailed else { continue }
            do { try writer.append(row) } catch { writeFailed = true }
        }
    }
}
