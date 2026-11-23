import Foundation

/// The time zone a session was recorded in. Line times are stored in UTC;
/// shown in whatever zone the Mac is in now, a show run in Phoenix and
/// opened back in Toronto would read two hours late.
public enum CaptureTimeZone {
    /// The zone stamped on the lines, else one worked out from the file
    /// name (see ``inferred(transcript:sessionStart:)``). Nil when neither
    /// tells.
    public static func of(_ segments: [TranscriptSegment], transcript: URL?) -> TimeZone? {
        if let zone = segments.lazy.compactMap({ $0.timeZone.flatMap(TimeZone.init(identifier:)) }).first {
            return zone
        }
        guard let transcript, let start = sessionStart(segments) else { return nil }
        return inferred(transcript: transcript, sessionStart: start)
    }

    /// Like ``of(_:transcript:)``, reading only the start of the file, for
    /// lists of many sessions.
    public static func read(transcript: URL, bytes: Int = 64 * 1024) -> TimeZone? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return of(TranscriptFile.segments(in: data), transcript: transcript)
    }

    /// Lines written before the zone was stamped on them. The file name is
    /// the start in the Mac's zone at the time, and the lines give the same
    /// moment in UTC, so the gap between them is the zone's offset. Only the
    /// offset is known, not the place: Phoenix and Denver read alike in
    /// winter. Zones sit on quarter hours; a name more than two minutes off
    /// one (a renamed file) gives nil. The first line lands seconds after
    /// the start, well inside that.
    static func inferred(transcript: URL, sessionStart: Date) -> TimeZone? {
        guard let wallClock = TranscriptFile.started(fromFileName: transcript, timeZone: .gmt) else { return nil }
        let seconds = wallClock.timeIntervalSince(sessionStart)
        let quarters = (seconds / 900).rounded()
        guard abs(seconds - quarters * 900) <= 120, abs(quarters) <= 14 * 4 else { return nil }
        return TimeZone(secondsFromGMT: Int(quarters) * 900)
    }

    /// The earliest `timestamp − sessionOffset`: each line lands a moment
    /// after it was heard, so the smallest gap is closest to the true start.
    static func sessionStart(_ segments: [TranscriptSegment]) -> Date? {
        segments.lazy.map { $0.timestamp.addingTimeInterval(-$0.sessionOffset) }.min()
    }
}

/// How to show a session's clock times: in the zone it was recorded in,
/// labelled ("5:23:06 PM MST") only when that differs from this Mac's.
public struct CaptureClock: Sendable, Equatable {
    /// The zone times are shown in: the capture zone, or this Mac's when
    /// that isn't known.
    public let timeZone: TimeZone
    /// True when the capture zone's offset differs from this Mac's.
    public let isLabelled: Bool
    private let local: TimeZone
    private let date: Date

    /// `date` is the session start; offsets are compared at that moment, so
    /// a zone that only differs by daylight saving is judged on the night.
    public init(capture: TimeZone?, local: TimeZone = .current, at date: Date) {
        self.timeZone = capture ?? local
        self.local = local
        self.date = date
        isLabelled = timeZone.secondsFromGMT(for: date) != local.secondsFromGMT(for: date)
    }

    /// Letters where there are any ("MST", "CET", "IST"), else the offset
    /// ("GMT+11"). See ``ZoneAbbreviation``.
    public var label: String { ZoneAbbreviation.letters(for: timeZone, at: date) }

    /// " MST" to append to a time, or "" when the zones agree.
    public var suffix: String { isLabelled ? " " + label : "" }

    /// `date` in `style`, in the capture zone, labelled when it differs.
    public func format(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = timeZone
        return date.formatted(style) + suffix
    }

    /// One line for the report header, nil when the zones agree.
    /// "Times are Phoenix time (MST), when it was recorded: 2 h behind this Mac."
    public var note: String? {
        guard isLabelled else { return nil }
        let place = timeZone.identifier.contains("/")
            ? timeZone.identifier.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ") + " time (\(label))"
            : label
        let minutes = (timeZone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)) / 60
        let gap = abs(minutes) % 60 == 0 ? "\(abs(minutes) / 60) h" : "\(abs(minutes) / 60) h \(abs(minutes) % 60) min"
        return "Times are \(place), when it was recorded: \(gap) \(minutes < 0 ? "behind" : "ahead of") this Mac."
    }
}

/// A zone's letters at a moment. The system gives them only for zones
/// common in the reader's region (on a US Mac, "MST" but "GMT+1" for Paris),
/// and none for a zone known only by its offset. Those are looked up in the
/// system's abbreviation table: a zone with the same offset at that moment,
/// preferring the same region, then the commonest, then matching daylight
/// saving.
enum ZoneAbbreviation {
    static func letters(for zone: TimeZone, at date: Date) -> String {
        let system = zone.abbreviation(for: date) ?? zone.identifier
        if system.allSatisfy(\.isLetter) { return system }
        let offset = zone.secondsFromGMT(for: date)
        // A fixed offset is taken as standard time; daylight is tried if
        // nothing standard fits (UTC−4 in July is EDT).
        let daylight = zone.isDaylightSavingTime(for: date)
        if offset == 0, !daylight { return "GMT" }
        let fitting = TimeZone.abbreviationDictionary.compactMap { letters, id -> (letters: String, id: String, daylight: Bool)? in
            guard letters.count >= 3, letters.allSatisfy(\.isUppercase),
                  let other = TimeZone(identifier: id), other.secondsFromGMT(for: date) == offset else { return nil }
            let isDaylight = daylightLetters.contains(letters)
            // The letters must be the ones in use there at that moment.
            guard isDaylight == other.isDaylightSavingTime(for: date) else { return nil }
            return (letters, id, isDaylight)
        }
        let region = zone.identifier.split(separator: "/").first.map(String.init)
        func rank(_ entry: (letters: String, id: String, daylight: Bool)) -> (Int, Int, Int, String) {
            (entry.id == zone.identifier ? 0 : entry.id.hasPrefix((region ?? "") + "/") ? 1 : 2,
             preferred.firstIndex(of: entry.id) ?? preferred.count,
             entry.daylight == daylight ? 0 : 1,
             entry.letters)
        }
        return fitting.min { rank($0) < rank($1) }?.letters ?? system
    }

    /// Daylight-saving letters in the system table.
    static let daylightLetters: Set<String> = [
        "ADT", "AKDT", "BRST", "BST", "CDT", "CEST", "CLST", "EDT", "EEST", "MDT", "MSD", "NDT", "NZDT", "PDT", "WEST",
    ]

    /// Ties between regions go to the commonest: UTC−5 is EST, not Bogotá's COT.
    static let preferred = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles",
        "America/Juneau", "Pacific/Honolulu", "America/Halifax", "Europe/London", "Europe/Paris", "Europe/Athens",
    ]
}
