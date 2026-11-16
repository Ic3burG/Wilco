import Foundation

/// How voice-change detection decides a new person is talking. Shared by
/// every channel that has it turned on.
public struct VoiceChangeSettings: Codable, Equatable, Sendable {
    /// Cosine distance between voices above which they count as different.
    public var threshold: Double = 0.5
    /// Seconds of silence after which the next line starts a new exchange.
    public var exchangeGap: Double = 20
    /// Lines shorter than this many seconds are too short to judge a voice by.
    public var shortLine: Double = 1.0

    public static let standard = VoiceChangeSettings()

    public init(threshold: Double = 0.5, exchangeGap: Double = 20, shortLine: Double = 1.0) {
        self.threshold = threshold
        self.exchangeGap = exchangeGap
        self.shortLine = shortLine
    }

    private enum CodingKeys: String, CodingKey { case threshold, exchangeGap, shortLine }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? Self.standard.threshold
        exchangeGap = try c.decodeIfPresent(Double.self, forKey: .exchangeGap) ?? Self.standard.exchangeGap
        shortLine = try c.decodeIfPresent(Double.self, forKey: .shortLine) ?? Self.standard.shortLine
    }
}
