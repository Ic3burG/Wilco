import Foundation

/// What the matrix gives a column to: each channel, or each group.
public enum MatrixMode: String, CaseIterable, Sendable {
    case channels, groups
}

/// One matrix column. Its `id` keys the column's width, collapse and text
/// size in `MatrixLayout`; channel and group UUIDs never collide.
public enum MatrixColumn: Identifiable, Equatable, Sendable {
    case channel(ChannelConfig)
    case group(ChannelGroup, channelCount: Int)

    public var id: UUID {
        switch self {
        case .channel(let channel): channel.id
        case .group(let group, _): group.id
        }
    }

    public var scope: ChannelScope {
        switch self {
        case .channel(let channel): .channel(channel.id)
        case .group(let group, _): .group(group.id)
        }
    }
}

extension ShowDocument {
    /// Channels mode: every channel in display order. Groups mode: the
    /// sidebar's top level, each non-empty group and ungrouped channel.
    public func matrixColumns(_ mode: MatrixMode) -> [MatrixColumn] {
        switch mode {
        case .channels:
            return channelsInDisplayOrder.map(MatrixColumn.channel)
        case .groups:
            return sidebarChildren(of: nil).compactMap { item -> MatrixColumn? in
                switch item {
                case .group(let id):
                    guard let group = group(id: id) else { return nil }
                    let count = channels(inGroup: id).count
                    return count == 0 ? nil : .group(group, channelCount: count)
                case .channel(let id):
                    return channel(id: id).map(MatrixColumn.channel)
                default:
                    return nil
                }
            }
        }
    }
}
