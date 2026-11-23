import Foundation

/// A show: everything Wilco saves in a `.wilco` file.
///
/// The JSON layout is `formatVersion` 1, so existing shows open
/// unchanged. Decoding tolerates missing keys by falling back to the
/// defaults below, the way a newer field added to an older file should behave.
public struct ShowDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    /// CoreAudio device UID. Channels are patched by UID so replugging an
    /// interface restores the same patch.
    public var deviceUID: String?
    public var channels: [ChannelConfig]
    public var groups: [ChannelGroup]
    /// Top-level sidebar order of folders and ungrouped channels. Optional:
    /// older shows lack it, and `nil` means folders first, then channels.
    /// Read through `sidebarChildren(of:)`, which repairs stale entries.
    public var sidebarOrder: [SidebarItem]? = nil
    public var rules: [AutomationRule]
    public var highlights: [HighlightRule]
    public var destinations: [OSCDestination]
    public var globalVocabulary: [String]
    /// Raw value of ``WhisperModel``. Kept as a string so an
    /// unknown model name from a newer file does not fail the whole show.
    public var whisperModel: String
    /// The engine a channel added to this show starts on. `nil` (older
    /// shows, and new ones until it is changed) means ``SpeechEngine/platformDefault``.
    public var defaultEngine: SpeechEngine? = nil
    /// The language a channel added to this show starts on, as stored in
    /// ``ChannelConfig/localeIdentifier``. `nil` means "en_US".
    public var defaultLocaleIdentifier: String? = nil
    public var mcpEnabled: Bool
    public var mcpPort: UInt16
    public var networkEnabled: Bool
    public var peerName: String
    public var mosEnabled: Bool
    public var mosHost: String
    public var mosPort: UInt16
    public var mosID: String
    public var mosNCSID: String
    /// Tuning for voice-change detection on channels that turn it on.
    public var voiceChanges: VoiceChangeSettings = .standard
    /// The report's run-of-show marker lists. `nil` until edited, meaning the
    /// built-in lists, so an unedited show's file has no `markers` key and
    /// picks up improvements to the built-in lists.
    public var markers: MarkerSettings? = nil

    /// The engine ``addChannel(engine:)`` uses. An Apple engine chosen on a
    /// newer Mac falls back to the platform default on one before macOS 26.
    public var newChannelEngine: SpeechEngine {
        guard let defaultEngine else { return .platformDefault }
        if defaultEngine.isApple, SpeechEngine.platformDefault == .whisper { return .platformDefault }
        return defaultEngine
    }

    /// The language ``addChannel(engine:)`` uses for a channel on `engine`.
    /// Detect Automatically becomes US English on Apple's engines, which
    /// must be told the language.
    public func newChannelLocale(for engine: SpeechEngine) -> String {
        let stored = defaultLocaleIdentifier ?? "en_US"
        if engine.isApple, stored == ChannelConfig.detectLanguageAutomatically { return "en_US" }
        return stored
    }

    /// The marker lists the report uses for this show.
    public var markerSettings: MarkerSettings { markers ?? .standard }

    public init(
        formatVersion: Int = ShowDocument.currentFormatVersion,
        name: String = "New Show",
        deviceUID: String? = nil,
        channels: [ChannelConfig] = [],
        groups: [ChannelGroup] = [],
        rules: [AutomationRule] = [],
        highlights: [HighlightRule] = [],
        destinations: [OSCDestination] = [],
        globalVocabulary: [String] = [],
        whisperModel: String = WhisperModel.base.rawValue,
        mcpEnabled: Bool = false,
        mcpPort: UInt16 = 8787,
        networkEnabled: Bool = false,
        peerName: String = "",
        mosEnabled: Bool = false,
        mosHost: String = "",
        mosPort: UInt16 = 10540,
        mosID: String = "wilco",
        mosNCSID: String = "NCS"
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.deviceUID = deviceUID
        self.channels = channels
        self.groups = groups
        self.rules = rules
        self.highlights = highlights
        self.destinations = destinations
        self.globalVocabulary = globalVocabulary
        self.whisperModel = whisperModel
        self.mcpEnabled = mcpEnabled
        self.mcpPort = mcpPort
        self.networkEnabled = networkEnabled
        self.peerName = peerName
        self.mosEnabled = mosEnabled
        self.mosHost = mosHost
        self.mosPort = mosPort
        self.mosID = mosID
        self.mosNCSID = mosNCSID
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, deviceUID, channels, groups, sidebarOrder, rules, highlights,
             destinations, globalVocabulary, whisperModel, defaultEngine, defaultLocaleIdentifier, mcpEnabled, mcpPort,
             networkEnabled, peerName, mosEnabled, mosHost, mosPort, mosID, mosNCSID, voiceChanges, markers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShowDocument()
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? d.formatVersion
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        channels = try c.decodeIfPresent([ChannelConfig].self, forKey: .channels) ?? d.channels
        groups = try c.decodeIfPresent([ChannelGroup].self, forKey: .groups) ?? d.groups
        // Strings, not SidebarItems, so an entry this build can't read is
        // skipped rather than failing the whole show.
        sidebarOrder = try c.decodeIfPresent([String].self, forKey: .sidebarOrder)?
            .compactMap(SidebarItem.init(storageValue:))
            .filter(\.isSidebarEntry)
        rules = try c.decodeIfPresent([AutomationRule].self, forKey: .rules) ?? d.rules
        highlights = try c.decodeIfPresent([HighlightRule].self, forKey: .highlights) ?? d.highlights
        destinations = try c.decodeIfPresent([OSCDestination].self, forKey: .destinations) ?? d.destinations
        globalVocabulary = try c.decodeIfPresent([String].self, forKey: .globalVocabulary) ?? d.globalVocabulary
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        // An engine this build does not know falls back to the platform default.
        defaultEngine = try c.decodeIfPresent(String.self, forKey: .defaultEngine).flatMap(SpeechEngine.init(rawValue:))
        defaultLocaleIdentifier = try c.decodeIfPresent(String.self, forKey: .defaultLocaleIdentifier)
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? d.mcpEnabled
        mcpPort = try c.decodeIfPresent(UInt16.self, forKey: .mcpPort) ?? d.mcpPort
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? d.networkEnabled
        peerName = try c.decodeIfPresent(String.self, forKey: .peerName) ?? d.peerName
        mosEnabled = try c.decodeIfPresent(Bool.self, forKey: .mosEnabled) ?? d.mosEnabled
        mosHost = try c.decodeIfPresent(String.self, forKey: .mosHost) ?? d.mosHost
        mosPort = try c.decodeIfPresent(UInt16.self, forKey: .mosPort) ?? d.mosPort
        mosID = try c.decodeIfPresent(String.self, forKey: .mosID) ?? d.mosID
        mosNCSID = try c.decodeIfPresent(String.self, forKey: .mosNCSID) ?? d.mosNCSID
        voiceChanges = try c.decodeIfPresent(VoiceChangeSettings.self, forKey: .voiceChanges) ?? d.voiceChanges
        markers = try c.decodeIfPresent(MarkerSettings.self, forKey: .markers)
        let channelTerms = try c.decodeIfPresent([LegacyChannelVocabulary].self, forKey: .channels)?
            .flatMap { $0.vocabulary ?? [] } ?? []
        globalVocabulary = Self.adding(channelTerms, to: globalVocabulary)
    }

    /// Older shows kept vocabulary on each channel as well as on the show.
    /// Only the show's list is edited now, so a channel's terms move into it
    /// when the file opens rather than staying where nobody can see them.
    private struct LegacyChannelVocabulary: Decodable {
        var vocabulary: [String]?
    }

    /// `terms` appended to `list`, trimmed, skipping blanks and any term
    /// already there in any letter case. `list` itself is left as it was.
    static func adding(_ terms: [String], to list: [String]) -> [String] {
        var seen = Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return list + terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Channel IDs are the only stable handle on a channel. Positions change
    /// whenever channels are reordered or deleted (see SPEC §11.1).
    public func channel(id: ChannelConfig.ID) -> ChannelConfig? {
        channels.first { $0.id == id }
    }
}
