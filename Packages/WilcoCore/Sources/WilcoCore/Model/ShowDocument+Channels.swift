import Foundation

/// Channel edits. Every operation addresses channels by ID: positions shift
/// on reorder and delete, and holding one across an edit is what crashed 0.2.0.
extension ShowDocument {
    /// Appends a channel named "Channel N", patched to the lowest unused input.
    @discardableResult
    public mutating func addChannel(engine: SpeechEngine = .longForm) -> ChannelConfig {
        let usedInputs = Set(channels.compactMap(\.deviceChannel))
        let freeInput = (0...).first { !usedInputs.contains($0) }
        let channel = ChannelConfig(
            name: "Channel \(channels.count + 1)",
            tint: ChannelTint.allCases[channels.count % ChannelTint.allCases.count],
            deviceChannel: freeInput,
            engine: engine
        )
        channels.append(channel)
        return channel
    }

    /// Removes the channel and any rule or highlight scoping that named it.
    public mutating func deleteChannel(id: ChannelConfig.ID) {
        channels.removeAll { $0.id == id }
        for index in rules.indices { rules[index].channelIDs.remove(id) }
        for index in highlights.indices { highlights[index].channelIDs.remove(id) }
    }

    /// Applies `change` to the channel if it still exists; otherwise does nothing.
    public mutating func updateChannel(id: ChannelConfig.ID, _ change: (inout ChannelConfig) -> Void) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        change(&channels[index])
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an offset in the
    /// list before the moved items are removed.
    public mutating func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.moveElements(fromOffsets: source, toOffset: destination)
    }
}

extension Array {
    /// SwiftUI's `move(fromOffsets:toOffset:)`, without importing SwiftUI.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let insertAt = destination - source.count { $0 < destination }
        for offset in source.reversed() { remove(at: offset) }
        insert(contentsOf: moving, at: insertAt)
    }
}
