import Foundation

/// One comms channel: a hardware input, how it is transcribed and how it looks.
public struct ChannelConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    public var tint: ChannelTint
    /// Input device for this channel; `nil` uses the show's device.
    public var deviceUID: String?
    /// Zero-based input on the capture device; `nil` means not patched.
    public var deviceChannel: Int?
    public var groupID: UUID?
    public var localeIdentifier: String
    public var engine: SpeechEngine
    public var latencyProfile: SpeechLatencyProfile
    /// A muted channel is still captured and metered, but not transcribed.
    public var isMuted: Bool
    /// Terms biased into this channel's recogniser.
    public var vocabulary: [String]
    /// Whisper only: write the transcript in English, whatever was spoken.
    public var translateToEnglish: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "person.wave.2",
        tint: ChannelTint = .blue,
        deviceUID: String? = nil,
        deviceChannel: Int? = nil,
        groupID: UUID? = nil,
        localeIdentifier: String = "en_US",
        engine: SpeechEngine = .longForm,
        latencyProfile: SpeechLatencyProfile = .leadAndCorrect,
        isMuted: Bool = false,
        vocabulary: [String] = [],
        translateToEnglish: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.deviceUID = deviceUID
        self.deviceChannel = deviceChannel
        self.groupID = groupID
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.latencyProfile = latencyProfile
        self.isMuted = isMuted
        self.vocabulary = vocabulary
        self.translateToEnglish = translateToEnglish
    }

    /// `localeIdentifier` for "Detect Automatically" (Whisper only).
    public static let detectLanguageAutomatically = ""

    /// Turning translation on also sets the language to Detect Automatically,
    /// the usual pairing for a channel that should come out in English
    /// whatever is spoken. Turning it off leaves the language alone.
    public mutating func setTranslateToEnglish(_ on: Bool) {
        translateToEnglish = on
        if on { localeIdentifier = Self.detectLanguageAutomatically }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, tint, deviceUID, deviceChannel, groupID, localeIdentifier,
             engine, latencyProfile, isMuted, vocabulary, translateToEnglish
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.wave.2"
        tint = try c.decodeIfPresent(ChannelTint.self, forKey: .tint) ?? .blue
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        // A negative input can only come from a damaged or hand-edited file.
        deviceChannel = try c.decodeIfPresent(Int.self, forKey: .deviceChannel).flatMap { $0 >= 0 ? $0 : nil }
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "en_US"
        engine = try c.decodeIfPresent(SpeechEngine.self, forKey: .engine) ?? .longForm
        latencyProfile = try c.decodeIfPresent(SpeechLatencyProfile.self, forKey: .latencyProfile) ?? .leadAndCorrect
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        translateToEnglish = try c.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
    }
}

public struct ChannelGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String

    public init(id: UUID = UUID(), name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

public enum ChannelTint: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, cyan, blue, indigo, purple, pink, gray
}

public enum SpeechEngine: String, Codable, CaseIterable, Sendable {
    /// Apple `SpeechTranscriber` (macOS 26): continuous speech, per-language model.
    case longForm
    /// Apple `DictationTranscriber` (macOS 26): short calls, uses the system dictation model.
    case dictation
    /// WhisperKit: one shared multilingual model; the only engine before macOS 26.
    case whisper
}

public enum SpeechLatencyProfile: String, Codable, CaseIterable, Sendable {
    /// A fast lead pass shows volatile words; an accurate pass replaces them.
    case leadAndCorrect
    /// One pass only.
    case single
}

public enum WhisperModel: String, Codable, CaseIterable, Sendable {
    case tiny, base, small, large

    /// Folder name in the `argmaxinc/whisperkit-coreml` model repository.
    public var variant: String {
        switch self {
        case .tiny: "openai_whisper-tiny"
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .large: "openai_whisper-large-v3"
        }
    }
}
