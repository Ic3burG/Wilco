import Foundation

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
