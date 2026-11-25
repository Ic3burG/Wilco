import Foundation

/// Settings › General › Keep sessions: moves old sessions to the Trash.
///
/// A session is every file in `Transcripts/` sharing one
/// `Session yyyy-MM-dd HHmm-ss` name: the transcript (`.jsonl`), the show it
/// was recorded with (`.wilco`), its diagnostics and its clips folder. Only
/// names that are exactly that pattern count, and the paths to move are
/// rebuilt from the name and these fixed extensions, never taken from what a
/// file says. Anything else in the folder is left alone.
///
/// It runs when Wilco opens, before capture or clip labelling can start, so
/// it never moves a file something is writing or reading.
public enum SessionRetention {
    /// How long to keep sessions. Never is the default: nothing is removed
    /// unless the operator chose a period.
    public enum Period: String, CaseIterable, Sendable, Identifiable {
        case never
        case days30
        case days90
        case year

        public var id: String { rawValue }

        public var days: Int? {
            switch self {
            case .never: nil
            case .days30: 30
            case .days90: 90
            case .year: 365
            }
        }

        public var title: String {
            switch self {
            case .never: "Forever"
            case .days30: "30 Days"
            case .days90: "90 Days"
            case .year: "1 Year"
            }
        }

        /// A missing or hand-edited value keeps everything.
        public static func restored(from raw: String?) -> Period {
            raw.flatMap(Period.init(rawValue:)) ?? .never
        }
    }

    /// `UserDefaults` key holding the chosen period's raw value.
    public static let storageKey = "transcripts.keepFor"

    /// The parts a session can have, beside its name.
    public static let extensions = [
        "jsonl", ShowFile.fileExtension, DiagnosticsFile.fileExtension, ClipsFolder.fileExtension,
    ]

    public struct Session: Hashable, Sendable {
        /// `Session yyyy-MM-dd HHmm-ss`, with no extension.
        public var name: String
        public var started: Date
    }

    public struct Outcome: Equatable, Sendable {
        /// Sessions whose every part reached the Trash.
        public var moved: Int = 0
        /// Sessions with a part that couldn't be moved; the rest stay.
        public var failed: [String] = []
    }

    public struct Usage: Equatable, Sendable {
        public var sessions: Int
        public var bytes: Int64
    }

    /// Moves a file or folder to the Trash.
    public typealias Trash = @Sendable (URL) throws -> Void

    public static let systemTrash: Trash = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The session a file name belongs to, if it is exactly a session name
    /// plus one of ``extensions``.
    ///
    /// Names are read as UTC: the age only needs to be right to the day, and
    /// a zone with no daylight saving reads every name back exactly, even one
    /// written in an hour this Mac's zone skips.
    public static func session(forFileName fileName: String) -> Session? {
        let url = URL(fileURLWithPath: fileName)
        guard extensions.contains(url.pathExtension) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name + "." + url.pathExtension == fileName, name.hasPrefix(prefix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count))
        let formatter = Self.formatter()
        guard let started = formatter.date(from: stamp), formatter.string(from: started) == stamp else { return nil }
        return Session(name: name, started: started)
    }

    /// Every session in `folder`, oldest first.
    public static func sessions(in folder: URL) -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.compactMap(session(forFileName:))).sorted { $0.name < $1.name }
    }

    /// Sessions that started more than the period before `now`.
    public static func expired(in folder: URL, keepFor period: Period, now: Date = .now) -> [Session] {
        guard let days = period.days else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions(in: folder).filter { $0.started < cutoff }
    }

    /// The parts of `session` that exist in `folder`.
    public static func files(of session: Session, in folder: URL) -> [URL] {
        extensions
            .map { folder.appendingPathComponent(session.name + "." + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves every expired session to the Trash, part by part. A part that
    /// fails leaves the session listed in ``Outcome/failed``; the others
    /// still go.
    @discardableResult
    public static func moveExpired(
        in folder: URL, keepFor period: Period, now: Date = .now, trash: Trash = systemTrash
    ) -> Outcome {
        var outcome = Outcome()
        for session in expired(in: folder, keepFor: period, now: now) {
            var allMoved = true
            for file in files(of: session, in: folder) {
                do { try trash(file) } catch { allMoved = false }
            }
            if allMoved { outcome.moved += 1 } else { outcome.failed.append(session.name) }
        }
        return outcome
    }

    /// How many sessions `folder` holds and the size of everything in it.
    public static func usage(in folder: URL) -> Usage {
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in files {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let sessions = Set(names.filter { $0.hasSuffix(".jsonl") }.compactMap(session(forFileName:))).count
        return Usage(sessions: sessions, bytes: bytes)
    }

    private static let prefix = "Session "

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmm-ss"
        formatter.isLenient = false
        return formatter
    }
}
