import Foundation

/// One saved configuration as the list shows it.
public struct ConfigurationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let channelCount: Int
    /// When the file was last written.
    public let savedAt: Date

    public init(id: UUID, name: String, channelCount: Int, savedAt: Date) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        self.savedAt = savedAt
    }
}

public struct ConfigurationImport: Equatable, Sendable {
    public var imported: [UUID] = []
    public var failed: [URL] = []

    public init(imported: [UUID] = [], failed: [URL] = []) {
        self.imported = imported
        self.failed = failed
    }
}

public enum ConfigurationError: Error, Equatable {
    case emptyName
    case nameTaken(String)
    case notFound
}

/// Saved show setups ("configurations"), one `‹UUID›.wilco` file each.
///
/// Each file is a plain ``ShowDocument``, the same format as `Current.wilco`
/// and exported show files. The UUID is the identity, so a rename never moves a
/// file; the name shown is the show's own `name`. Names are unique ignoring
/// case so the title menu is never ambiguous.
public struct ConfigurationStore: Sendable {
    public static let defaultName = "New Show"

    public let directory: URL

    public init(directory: URL = DataLocations.configurations) {
        self.directory = directory
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(ShowFile.fileExtension)")
    }

    // MARK: Reading

    /// Every readable configuration, sorted by name. Files that don't decode,
    /// or aren't named by a UUID, are skipped and left alone.
    public func list() -> [ConfigurationSummary] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        let decoder = WilcoJSON.decoder()
        return urls.compactMap { url -> ConfigurationSummary? in
            guard url.pathExtension == ShowFile.fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let show = try? decoder.decode(ShowDocument.self, from: data) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return ConfigurationSummary(id: id, name: show.name, channelCount: show.channels.count, savedAt: modified ?? .distantPast)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(id).path)
    }

    public func document(_ id: UUID) throws -> ShowDocument {
        guard let data = try? Data(contentsOf: fileURL(id)) else { throw ConfigurationError.notFound }
        return try WilcoJSON.decoder().decode(ShowDocument.self, from: data)
    }

    // MARK: Writing

    public func write(_ document: ShowDocument, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WilcoJSON.encoder().encode(document).write(to: fileURL(id), options: .atomic)
    }

    /// Saves `document` as a new configuration under a unique version of its name.
    @discardableResult
    public func create(_ document: ShowDocument) throws -> UUID {
        var document = document
        document.name = uniqueName(document.name)
        let id = UUID()
        try write(document, id: id)
        return id
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> ShowDocument {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.emptyName }
        if let other = list().first(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw ConfigurationError.nameTaken(other.name)
        }
        var document = try document(id)
        document.name = trimmed
        try write(document, id: id)
        return document
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> UUID {
        var copy = try document(id)
        copy.name += " copy"
        return try create(copy)
    }

    public func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(id))
        } catch CocoaError.fileNoSuchFile {
            throw ConfigurationError.notFound
        }
    }

    // MARK: Import, export, migration

    /// Adds each readable `.wilco` show file as a new
    /// configuration. Unreadable files are reported, not fatal.
    public func importFiles(_ urls: [URL]) -> ConfigurationImport {
        var result = ConfigurationImport()
        let decoder = WilcoJSON.decoder()
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let show = try? decoder.decode(ShowDocument.self, from: data),
               let id = try? create(show) {
                result.imported.append(id)
            } else {
                result.failed.append(url)
            }
        }
        return result
    }

    /// Writes the saved version (not any unsaved working copy).
    public func export(_ id: UUID, to url: URL) throws {
        try WilcoJSON.encoder().encode(document(id)).write(to: url, options: .atomic)
    }

    /// First launch with configurations: keeps the show the user already has
    /// as the first one. Returns its ID, or `nil` if any configuration exists.
    public func migrateIfEmpty(from current: ShowDocument) throws -> UUID? {
        guard list().isEmpty else { return nil }
        return try create(current)
    }

    // MARK: Names

    /// `proposed` trimmed, or "New Show" if blank, with " 2", " 3"… added
    /// until no other configuration has it (ignoring case).
    public func uniqueName(_ proposed: String, excluding: UUID? = nil) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? Self.defaultName : trimmed
        let taken = Set(list().filter { $0.id != excluding }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0.lowercased()) }!
    }
}
