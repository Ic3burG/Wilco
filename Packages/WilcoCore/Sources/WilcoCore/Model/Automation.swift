import Foundation

public enum KeywordMatchMode: String, Codable, CaseIterable, Sendable {
    case containsAny, containsAll, startsWith, regularExpression
}

/// Fires actions when a phrase is heard.
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var phrases: [String]
    public var matchMode: KeywordMatchMode
    /// Channels the rule listens to; empty means every channel.
    public var channelIDs: Set<UUID>
    /// Seconds during which a repeat match does not fire again.
    public var cooldown: Double
    public var actions: [AutomationAction]

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        phrases: [String] = [],
        matchMode: KeywordMatchMode = .containsAny,
        channelIDs: Set<UUID> = [],
        cooldown: Double = 0,
        actions: [AutomationAction] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.phrases = phrases
        self.matchMode = matchMode
        self.channelIDs = channelIDs
        self.cooldown = cooldown
        self.actions = actions
    }
}

/// Tints matching words in the transcript; fires nothing.
public struct HighlightRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var phrases: [String]
    public var matchMode: KeywordMatchMode
    public var channelIDs: Set<UUID>
    public var tint: ChannelTint

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        phrases: [String] = [],
        matchMode: KeywordMatchMode = .containsAny,
        channelIDs: Set<UUID> = [],
        tint: ChannelTint = .yellow
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.phrases = phrases
        self.matchMode = matchMode
        self.channelIDs = channelIDs
        self.tint = tint
    }
}

/// What a rule does when it fires.
///
/// Uses Swift's synthesized `Codable`, which is the format 0.2.0 wrote:
/// `{"osc":{"destinationID":…,"address":…,"arguments":[…]}}`.
public enum AutomationAction: Codable, Equatable, Sendable {
    case osc(destinationID: UUID, address: String, arguments: [OSCArgument])
    /// `endpointID` is the CoreMIDI unique ID of the destination.
    case midi(endpointID: Int32, message: MIDIMessageSpec)
    case webhook(urlTemplate: String, method: String, bodyTemplate: String)
    case notify(title: String, bodyTemplate: String)
    case markCuePoint(label: String)
}

public enum MIDIMessageSpec: Codable, Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    /// MIDI Show Control GO.
    case mscGo(deviceID: UInt8, cueNumber: String, cueList: String)
}

/// A typed OSC argument. Named `OSCMessage.Argument` in 0.2.0; the JSON is
/// identical because synthesized coding uses case names, not type names.
public enum OSCArgument: Codable, Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)
}
