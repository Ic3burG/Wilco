import Foundation
import Synchronization
import WilcoCore

/// Keeps some of a capture session's finished lines as clips in the session's
/// `.clips` folder. Transcribers offer every final line's audio through
/// ``tap``; a ``ClipSelector`` decides which to hold, write or delete, and the
/// keeper saves `clips.json` as it goes and when the session finishes.
///
/// Offering never waits for the keeper: offers queue up to `queueLimit`, and
/// any beyond that are dropped and counted in the manifest. A failed write
/// stops new clips for the session (deletes and a last manifest save still
/// run, so the files and the manifest agree); transcription carries on.
public actor ClipKeeper {
    /// Counts offers dropped because the queue was full. Shared with the tap,
    /// which runs on the transcribers' actors.
    private final class DropCounter: Sendable {
        let count = Mutex(0)
    }

    private let folder: URL
    private var selector: ClipSelector
    private let continuation: AsyncStream<ClipOffer>.Continuation
    private var stream: AsyncStream<ClipOffer>?
    private let drops: DropCounter
    private var finished = false
    private var drainTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?

    /// Offers the selector is holding and that aren't written yet.
    private var held: [UUID: ClipOffer] = [:]
    /// Ids whose WAV is on disk.
    private var written: Set<UUID> = []
    private var records: [ClipRecord] = []
    private var changed = false
    private var savedDropped = 0
    private var writeFailed = false

    /// Where transcribers offer each finished line.
    public nonisolated let tap: ClipTap

    /// - Parameters:
    ///   - folder: The session's `.clips` folder; created on the first write.
    ///   - queueLimit: Offers waiting to be handled before new ones are dropped.
    ///   - saveInterval: Seconds between saves of a changed manifest; nil
    ///     saves only in ``finish()``.
    public init(
        folder: URL, selector: ClipSelector = ClipSelector(), queueLimit: Int = 32, saveInterval: Double? = 5
    ) {
        self.folder = folder
        self.selector = selector
        let drops = DropCounter()
        self.drops = drops
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClipOffer.self, bufferingPolicy: .bufferingOldest(queueLimit))
        self.continuation = continuation
        self.stream = stream
        self.tap = ClipTap { offer in
            if case .dropped = continuation.yield(offer) {
                drops.count.withLock { $0 += 1 }
            }
        }
        // The actor starts its own tasks once it exists.
        Task { await self.start(saveInterval: saveInterval) }
    }

    private func start(saveInterval: Double?) {
        guard !finished, let stream else { return }
        self.stream = nil
        drainTask = Task { [weak self] in
            for await offer in stream {
                await self?.accept(offer)
            }
        }
        if let saveInterval {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(saveInterval))
                    if Task.isCancelled { break }
                    guard let self else { return }
                    await self.saveIfChanged()
                }
            }
        }
    }

    /// Stops taking offers, handles the ones already queued, closes every open
    /// run and saves the manifest.
    public func finish() async {
        loopTask?.cancel()
        continuation.finish()
        if !finished, let stream {
            // The drain never started; drain here.
            self.stream = nil
            for await offer in stream { accept(offer) }
        }
        finished = true
        await drainTask?.value
        apply(selector.finish(), current: nil)
        held.removeAll()
        // One last try even after a failed write, so the manifest on disk
        // matches the WAVs that made it.
        saveIfChanged(evenAfterFailure: true)
    }

    /// The manifest as it stands. For tests.
    var manifest: ClipManifest {
        ClipManifest(clips: records, dropped: drops.count.withLock { $0 })
    }

    private func accept(_ offer: ClipOffer) {
        let changes = selector.offer(offer.candidate, samplesEmpty: offer.samples.isEmpty)
        apply(changes, current: offer)
    }

    private func apply(_ changes: [ClipChange], current: ClipOffer?) {
        for change in changes {
            switch change {
            case .hold(let id):
                if !written.contains(id), let current, current.candidate.id == id {
                    held[id] = current
                }
            case .keep(let id, let kind, let exchange):
                keep(id, kind: kind, exchange: exchange, current: current)
            case .remove(let id):
                remove(id)
            }
        }
    }

    private func keep(_ id: UUID, kind: ClipKind, exchange: Int?, current: ClipOffer?) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].kind = kind
            records[index].exchange = exchange
            changed = true
            return
        }
        guard !writeFailed else { return }
        let source = held[id] ?? (current?.candidate.id == id ? current : nil)
        guard let offer = source else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WAV.encode(offer.samples).write(to: ClipsFolder.audioURL(for: id, in: folder), options: .atomic)
        } catch {
            writeFailed = true
            return
        }
        // Written: the record carries everything later changes need.
        held[id] = nil
        written.insert(id)
        let line = offer.candidate
        records.append(ClipRecord(
            id: id, channel: line.channel, kind: kind, sessionOffset: line.sessionOffset,
            duration: line.duration, confidence: line.confidence, engine: offer.engine,
            whisperModel: offer.whisperModel, exchange: exchange))
        changed = true
    }

    /// Deletes even after a failed write, since deleting frees space. The
    /// record goes only once the file is gone, so the manifest never lists a
    /// missing file and never misses one that's still there.
    private func remove(_ id: UUID) {
        held[id] = nil
        guard written.contains(id) else { return }
        let url = ClipsFolder.audioURL(for: id, in: folder)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
        }
        written.remove(id)
        records.removeAll { $0.id == id }
        changed = true
    }

    /// Saves the manifest when a record or the drop count changed since the
    /// last save. A session that never kept or dropped anything makes no folder.
    private func saveIfChanged(evenAfterFailure: Bool = false) {
        let current = manifest
        guard evenAfterFailure || !writeFailed, changed || current.dropped != savedDropped else { return }
        do {
            try ClipsFolder.save(current, in: folder)
            changed = false
            savedDropped = current.dropped
        } catch {
            writeFailed = true
        }
    }
}
