import Foundation

/// What the main window shows. Persisted under the `sidebar.selection` default.
public enum SidebarItem: Hashable, Sendable {
    case combined
    case matrix
    case activity
    case channel(UUID)
    /// A sidebar folder: the transcript of its channels only.
    case group(UUID)

    public init?(storageValue: String) {
        switch storageValue {
        case "combined": self = .combined
        case "matrix": self = .matrix
        case "activity": self = .activity
        default:
            if let id = Self.id(in: storageValue, after: "channel:") {
                self = .channel(id)
            } else if let id = Self.id(in: storageValue, after: "group:") {
                self = .group(id)
            } else {
                return nil
            }
        }
    }

    public var storageValue: String {
        switch self {
        case .combined: "combined"
        case .matrix: "matrix"
        case .activity: "activity"
        case .channel(let id): "channel:\(id.uuidString)"
        case .group(let id): "group:\(id.uuidString)"
        }
    }

    /// A folder or channel: what the sidebar's channel list holds and drags.
    public var isSidebarEntry: Bool {
        switch self {
        case .channel, .group: true
        case .combined, .matrix, .activity: false
        }
    }

    private static func id(in storageValue: String, after prefix: String) -> UUID? {
        guard storageValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(storageValue.dropFirst(prefix.count)))
    }

    /// This selection if it still refers to something in `show`, otherwise
    /// the combined transcript.
    public func validated(in show: ShowDocument) -> SidebarItem {
        switch self {
        case .channel(let id) where show.channel(id: id) == nil: .combined
        case .group(let id) where show.group(id: id) == nil: .combined
        default: self
        }
    }
}

/// Encoded as its storage value, e.g. `"group:<uuid>"`.
extension SidebarItem: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let item = SidebarItem(storageValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sidebar item \(value)"))
        }
        self = item
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}
