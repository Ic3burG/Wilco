import Foundation

/// Which channels a transcript shows: every channel, one channel, or one
/// sidebar group. Chips narrow `.all` and `.group` further, never widen them.
public enum ChannelScope: Hashable, Sendable {
    case all
    case channel(UUID)
    case group(UUID)

    /// The channels in scope, in display order. A missing channel or group has none.
    public func channels(in show: ShowDocument) -> [ChannelConfig] {
        switch self {
        case .all: show.channelsInDisplayOrder
        case .channel(let id): show.channel(id: id).map { [$0] } ?? []
        case .group(let id): show.group(id: id) == nil ? [] : show.channels(inGroup: id)
        }
    }

    /// Resolves the scope and chips once, so a long transcript can be filtered
    /// with a set lookup per line. Agrees with `includes` everywhere.
    public func filter(in show: ShowDocument, narrowedTo chips: Set<UUID>) -> ChannelFilter {
        switch self {
        case .all:
            let live = chips.filter { show.channel(id: $0) != nil }
            // nil: any channel, including ones since deleted from the show.
            return ChannelFilter(ids: live.isEmpty ? nil : live, showsChannelless: true)
        case .channel(let id):
            return ChannelFilter(ids: [id], showsChannelless: false)
        case .group:
            let members = Set(channels(in: show).map(\.id))
            let live = chips.intersection(members)
            return ChannelFilter(ids: live.isEmpty ? members : live, showsChannelless: true)
        }
    }

    /// Whether a line or marker from `channelID` belongs in this view. A `nil`
    /// channel (a marker no channel dropped) shows everywhere but a single
    /// channel's view. Empty `chips` means no narrowing, and chips naming no
    /// channel in scope are ignored, so a stale chip can't blank the view. A
    /// channel's own view ignores chips.
    public func includes(_ channelID: UUID?, in show: ShowDocument, narrowedTo chips: Set<UUID>) -> Bool {
        guard let channelID else {
            if case .channel = self { return false }
            return true
        }
        switch self {
        case .all:
            break
        case .channel(let id):
            return channelID == id
        case .group:
            guard isMember(channelID, of: show) else { return false }
        }
        let live = chips.filter { isMember($0, of: show) }
        return live.isEmpty || live.contains(channelID)
    }

    private func isMember(_ channelID: UUID, of show: ShowDocument) -> Bool {
        switch self {
        case .all:
            return show.channel(id: channelID) != nil
        case .channel(let id):
            return channelID == id
        case .group(let id):
            guard show.group(id: id) != nil, let channel = show.channel(id: channelID) else { return false }
            return show.effectiveGroupID(of: channel) == id
        }
    }
}

/// A `ChannelScope` resolved against a show and its chips.
public struct ChannelFilter: Sendable {
    /// The channels shown; nil shows every channel.
    let ids: Set<UUID>?
    /// Whether markers no channel dropped are shown.
    let showsChannelless: Bool

    public func includes(_ channelID: UUID?) -> Bool {
        guard let channelID else { return showsChannelless }
        return ids?.contains(channelID) ?? true
    }
}
