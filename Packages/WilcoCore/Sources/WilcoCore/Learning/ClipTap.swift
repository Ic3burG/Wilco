import Foundation
import Synchronization

/// A finished line's 16 kHz mono audio, offered for keeping as a clip.
public struct ClipOffer: Sendable {
    public var candidate: ClipCandidate
    /// `SpeechEngine` raw value.
    public var engine: String
    /// `WhisperModel` raw value, Whisper channels only.
    public var whisperModel: String?
    public var samples: [Float]

    public init(candidate: ClipCandidate, engine: String, whisperModel: String? = nil, samples: [Float]) {
        self.candidate = candidate
        self.engine = engine
        self.whisperModel = whisperModel
        self.samples = samples
    }
}

/// Where transcribers send each finished line's audio. Offering never blocks
/// and never throws; a full queue drops the offer.
public struct ClipTap: Sendable {
    public var offer: @Sendable (ClipOffer) -> Void

    public init(offer: @escaping @Sendable (ClipOffer) -> Void) {
        self.offer = offer
    }
}

/// Turns clip keeping on and off while a capture runs. Channels hold the
/// switch for the whole session and ask it, line by line, where to offer
/// clips, so a change reaches channels that are already transcribing.
///
/// Turned on partway through, it takes only lines that start after that
/// moment: a line already under way may have audio that wasn't kept.
public final class ClipSwitch: Sendable {
    private struct On: Sendable {
        var tap: ClipTap
        var since: Double
    }

    private let state = Mutex<On?>(nil)

    public init() {}

    /// Starts offering lines that begin at `sessionOffset` or later to `tap`.
    public func turnOn(_ tap: ClipTap, from sessionOffset: Double = 0) {
        state.withLock { $0 = On(tap: tap, since: sessionOffset) }
    }

    /// Stops offering at once. Clips already offered are still kept.
    public func turnOff() {
        state.withLock { $0 = nil }
    }

    public var isOn: Bool { state.withLock { $0 != nil } }

    /// Where to offer a line that starts at `lineStart`, or nil to keep none.
    public func tap(forLineStartingAt lineStart: Double) -> ClipTap? {
        state.withLock { on in
            guard let on, lineStart >= on.since else { return nil }
            return on.tap
        }
    }
}
