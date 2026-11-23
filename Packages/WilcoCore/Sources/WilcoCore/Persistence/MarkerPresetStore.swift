import Foundation

/// A named set of report markers that any show can load as a starting point.
public struct MarkerPreset: Codable, Equatable, Identifiable, Sendable {
    /// From the file name, not stored in the file.
    public var id: UUID
    public var name: String
    public var markers: MarkerSettings

    public init(id: UUID = UUID(), name: String, markers: MarkerSettings) {
        self.id = id
        self.name = name
        self.markers = markers
    }

    private enum CodingKeys: String, CodingKey {
        case name, markers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Preset"
        markers = try c.decodeIfPresent(MarkerSettings.self, forKey: .markers) ?? .standard
    }
}

/// Marker presets, one `‹UUID›.json` file each. As with configurations, the
/// UUID is the identity, so a rename never moves a file, and names are unique
/// ignoring case. Shows keep their own copy of a loaded preset; presets are
/// only read when one is loaded.
public struct MarkerPresetStore: Sendable {
    public static let fileExtension = "json"

    public let directory: URL

    public init(directory: URL = DataLocations.markerPresets) {
        self.directory = directory
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(Self.fileExtension)")
    }

    // MARK: Reading

    /// Every readable preset, sorted by name. Files that don't decode, or
    /// aren't named by a UUID, are skipped and left alone.
    public func list() -> [MarkerPreset] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return urls.compactMap { url -> MarkerPreset? in
            guard url.pathExtension == Self.fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? preset(id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func preset(_ id: UUID) throws -> MarkerPreset {
        guard let data = try? Data(contentsOf: fileURL(id)) else { throw ConfigurationError.notFound }
        var preset = try WilcoJSON.decoder().decode(MarkerPreset.self, from: data)
        preset.id = id
        return preset
    }

    /// The preset with this name, ignoring case and surrounding spaces.
    public func existing(named name: String) -> MarkerPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return list().first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: Writing

    /// Saves a new preset, or replaces the one already using this name
    /// (keeping its file and its spelling of the name).
    @discardableResult
    public func save(name: String, markers: MarkerSettings) throws -> MarkerPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.emptyName }
        let existing = existing(named: trimmed)
        let preset = MarkerPreset(id: existing?.id ?? UUID(), name: existing?.name ?? trimmed, markers: markers)
        try write(preset)
        return preset
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> MarkerPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.emptyName }
        if let other = existing(named: trimmed), other.id != id {
            throw ConfigurationError.nameTaken(other.name)
        }
        var preset = try preset(id)
        preset.name = trimmed
        try write(preset)
        return preset
    }

    public func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(id))
        } catch CocoaError.fileNoSuchFile {
            throw ConfigurationError.notFound
        }
    }

    private func write(_ preset: MarkerPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WilcoJSON.encoder().encode(preset).write(to: fileURL(preset.id), options: .atomic)
    }
}
