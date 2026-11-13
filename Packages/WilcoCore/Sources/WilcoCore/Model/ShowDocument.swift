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
    public var mcpEnabled: Bool
    public var mcpPort: UInt16
    public var networkEnabled: Bool
    public var peerName: String
    public var mosEnabled: Bool
    public var mosHost: String
    public var mosPort: UInt16
    public var mosID: String
    public var mosNCSID: String

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
             destinations, globalVocabulary, whisperModel, mcpEnabled, mcpPort,
             networkEnabled, peerName, mosEnabled, mosHost, mosPort, mosID, mosNCSID
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
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? d.mcpEnabled
        mcpPort = try c.decodeIfPresent(UInt16.self, forKey: .mcpPort) ?? d.mcpPort
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? d.networkEnabled
        peerName = try c.decodeIfPresent(String.self, forKey: .peerName) ?? d.peerName
        mosEnabled = try c.decodeIfPresent(Bool.self, forKey: .mosEnabled) ?? d.mosEnabled
        mosHost = try c.decodeIfPresent(String.self, forKey: .mosHost) ?? d.mosHost
        mosPort = try c.decodeIfPresent(UInt16.self, forKey: .mosPort) ?? d.mosPort
        mosID = try c.decodeIfPresent(String.self, forKey: .mosID) ?? d.mosID
        mosNCSID = try c.decodeIfPresent(String.self, forKey: .mosNCSID) ?? d.mosNCSID
    }

    /// Channel IDs are the only stable handle on a channel. Positions change
    /// whenever channels are reordered or deleted (see SPEC §11.1).
    public func channel(id: ChannelConfig.ID) -> ChannelConfig? {
        channels.first { $0.id == id }
    }
}
