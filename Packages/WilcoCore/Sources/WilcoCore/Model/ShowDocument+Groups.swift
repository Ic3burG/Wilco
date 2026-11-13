import Foundation

/// Channel groups: sidebar folders that filter what is shown. They never
/// change what is captured or transcribed.
///
/// Display order is folders in `groups` order, each folder's channels in
/// `channels` order, then ungrouped channels. Every group edit leaves the
/// `channels` array itself in that order, so 0.2.0 and every view agree.
extension ShowDocument {
    public func group(id: ChannelGroup.ID) -> ChannelGroup? {
        groups.first { $0.id == id }
    }

    /// The channel's group, or `nil` when it has none or names a group that
    /// doesn't exist (a hand-edited file, say). Such channels show as ungrouped.
    public func effectiveGroupID(of channel: ChannelConfig) -> ChannelGroup.ID? {
        guard let id = channel.groupID, group(id: id) != nil else { return nil }
        return id
    }

    /// A folder's channels in order; `nil` means the ungrouped channels.
    public func channels(inGroup id: ChannelGroup.ID?) -> [ChannelConfig] {
        channels.filter { effectiveGroupID(of: $0) == id }
    }

    /// What the sidebar shows under `parent`: a folder's channels, or for
    /// `nil` the top level, folders and ungrouped channels in stored order.
    /// Stale entries are skipped; anything missing is appended.
    public func sidebarChildren(of parent: ChannelGroup.ID?) -> [SidebarItem] {
        if let parent {
            guard group(id: parent) != nil else { return [] }
            return channels(inGroup: parent).map { .channel($0.id) }
        }
        var seen = Set<SidebarItem>()
        let stored = (sidebarOrder ?? []).filter { isTopLevel($0) && seen.insert($0).inserted }
        let all = groups.map { SidebarItem.group($0.id) } + channels(inGroup: nil).map { .channel($0.id) }
        return stored + all.filter { seen.insert($0).inserted }
    }

    public var channelsInDisplayOrder: [ChannelConfig] {
        sidebarChildren(of: nil).flatMap { item -> [ChannelConfig] in
            switch item {
            case .group(let id): channels(inGroup: id)
            case .channel(let id): channel(id: id).map { [$0] } ?? []
            default: []
            }
        }
    }

    private func isTopLevel(_ item: SidebarItem) -> Bool {
        switch item {
        case .group(let id): group(id: id) != nil
        case .channel(let id): channel(id: id).map { effectiveGroupID(of: $0) == nil } ?? false
        default: false
        }
    }

    // MARK: Editing groups

    @discardableResult
    public mutating func addGroup(name: String = "New Group", symbol: String = "folder") -> ChannelGroup {
        let group = ChannelGroup(name: name, symbol: symbol)
        // Pin the current order first, so the new folder goes last rather
        // than after the other folders.
        sidebarOrder = sidebarChildren(of: nil) + [.group(group.id)]
        groups.append(group)
        normalizeChannelOrder()
        return group
    }

    /// Ignores a name that is blank once trimmed.
    public mutating func renameGroup(id: ChannelGroup.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        normalizeChannelOrder()
    }

    public mutating func setGroupSymbol(id: ChannelGroup.ID, _ symbol: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].symbol = symbol
        normalizeChannelOrder()
    }

    /// Removes the group only; its channels become ungrouped, in its place.
    public mutating func deleteGroup(id: ChannelGroup.ID) {
        guard group(id: id) != nil else { return }
        let members = sidebarChildren(of: id)
        sidebarOrder = sidebarChildren(of: nil).flatMap { $0 == .group(id) ? members : [$0] }
        groups.removeAll { $0.id == id }
        normalizeChannelOrder()
    }

    // MARK: Moving

    /// Whether `items` may go under `parent`: known folders and channels
    /// only, and folders only at the top level (no nesting).
    public func canMoveSidebarItems(_ items: [SidebarItem], toParent parent: ChannelGroup.ID?) -> Bool {
        guard !items.isEmpty else { return false }
        if let parent, group(id: parent) == nil { return false }
        return items.allSatisfy { item in
            switch item {
            case .group(let id): parent == nil && group(id: id) != nil
            case .channel(let id): channel(id: id) != nil
            default: false
            }
        }
    }

    /// A sidebar drop: puts `items` under `parent` (`nil` for the top level)
    /// at `index` in that list as shown, dragged rows included, as
    /// NSOutlineView counts. An index past the end appends. Does nothing
    /// unless `canMoveSidebarItems` allows it.
    public mutating func moveSidebarItems(_ items: [SidebarItem], toParent parent: ChannelGroup.ID?, at index: Int) {
        guard canMoveSidebarItems(items, toParent: parent) else { return }
        var seen = Set<SidebarItem>()
        let moving = items.filter { seen.insert($0).inserted }

        let target = sidebarChildren(of: parent)
        let insertAt = target.prefix(max(index, 0)).count { !seen.contains($0) }

        var root = sidebarChildren(of: nil).filter { !seen.contains($0) }
        var members = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.id, sidebarChildren(of: group.id).filter { !seen.contains($0) })
        })
        if let parent {
            members[parent, default: []].insert(contentsOf: moving, at: insertAt)
        } else {
            root.insert(contentsOf: moving, at: insertAt)
        }

        for case .channel(let id) in moving {
            updateChannel(id: id) { $0.groupID = parent }
        }
        let byID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        channels = root.flatMap { item -> [ChannelConfig] in
            switch item {
            case .group(let id): (members[id] ?? []).compactMap { if case .channel(let c) = $0 { byID[c] } else { nil } }
            case .channel(let id): byID[id].map { [$0] } ?? []
            default: []
            }
        }
        sidebarOrder = root
        normalizeChannelOrder()
    }

    /// Moves the channel to the end of `groupID`'s folder, or of the top
    /// level for `nil`. Does nothing for a missing group or channel.
    public mutating func assignChannel(_ channelID: ChannelConfig.ID, toGroup groupID: ChannelGroup.ID?) {
        moveSidebarItems([.channel(channelID)], toParent: groupID, at: .max)
    }

    /// Clears dangling group IDs, stores the repaired top-level order, and
    /// puts `groups` and `channels` in sidebar order, so 0.2.0 and every
    /// view agree.
    private mutating func normalizeChannelOrder() {
        for index in channels.indices where effectiveGroupID(of: channels[index]) == nil {
            channels[index].groupID = nil
        }
        let root = sidebarChildren(of: nil)
        sidebarOrder = root
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        groups = root.compactMap { if case .group(let id) = $0 { groupsByID[id] } else { nil } }
        channels = channelsInDisplayOrder
    }
}
