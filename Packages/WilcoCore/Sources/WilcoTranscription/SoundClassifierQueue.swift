import AVFoundation
import Foundation
import SoundAnalysis
import WilcoCore

/// Classifies the diagnostics clips of every channel, one at a time. The
/// classifier is heavy next to the work it must not disturb, so clips wait in
/// line at low priority, and a clip that finds the line full is dropped.
public actor SoundClassifierQueue {
    private let maxWaiting: Int
    private let work: @Sendable (MeterClip) async -> SoundShares?
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var droppedClips = 0

    public init(
        maxWaiting: Int = 64,
        classify: @escaping @Sendable (MeterClip) async -> SoundShares? = SoundClassifierQueue.builtIn
    ) {
        self.maxWaiting = maxWaiting
        self.work = classify
    }

    /// The clip's speech, music and singing shares, or nil when the line is
    /// full (the clip is dropped at once) or the classifier fails.
    public func classify(_ clip: MeterClip) async -> SoundShares? {
        if running {
            guard waiters.count < maxWaiting else {
                droppedClips += 1
                return nil
            }
            // The turn is handed over with `running` still set, so a newcomer
            // can't jump the line between the hand-over and the resume.
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running = true
        }
        let work = work
        let shares = await Task.detached(priority: .utility) { await work(clip) }.value
        if waiters.isEmpty {
            running = false
        } else {
            waiters.removeFirst().resume()
        }
        return shares
    }

    /// Apple's built-in sound classifier, keeping the highest confidence each
    /// label reached in any window of the clip. Nil on any error.
    public static func builtIn(_ clip: MeterClip) async -> SoundShares? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: analyze(clip))
            }
        }
    }

    private static func analyze(_ clip: MeterClip) -> SoundShares? {
        guard !clip.samples.isEmpty, clip.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = buffer.floatChannelData?[0],
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else { return nil }
        clip.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: clip.samples.count) }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)

        let observer = MaxConfidenceObserver()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
        } catch {
            return nil
        }
        return observer.result()
    }
}

/// Collects, per label, the highest confidence over all windows.
private final class MaxConfidenceObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var best: [String: Double] = [:]
    private var sawResult = false
    private var failed = false

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        defer { lock.unlock() }
        sawResult = true
        for label in ["speech", "music", "singing"] {
            if let confidence = result.classification(forIdentifier: label)?.confidence {
                best[label] = max(best[label] ?? 0, confidence)
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        failed = true
        lock.unlock()
    }

    func result() -> SoundShares? {
        lock.lock()
        defer { lock.unlock() }
        guard sawResult, !failed else { return nil }
        return SoundShares(speech: best["speech"] ?? 0, music: best["music"] ?? 0, singing: best["singing"] ?? 0)
    }
}
