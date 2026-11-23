import Foundation

/// JSON settings shared by every Wilco file and wire format.
///
/// Dates are ISO-8601 with whole seconds (`2026-11-08T02:25:25Z`), in shows,
/// transcripts and peer lines alike.
public enum WilcoJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum TranscriptFile {
    /// `Session yyyy-MM-dd HHmm-ss.jsonl`, in local time.
    public static func fileName(for sessionStart: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm-ss"
        return "Session \(formatter.string(from: sessionStart)).jsonl"
    }

    /// The start time a session's file name gives, read as being in
    /// `timeZone`; nil for a file not named by ``fileName(for:timeZone:)``.
    public static func started(fromFileName url: URL, timeZone: TimeZone = .current) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Session ") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm-ss"
        return formatter.date(from: String(name.dropFirst("Session ".count)))
    }

    /// One line of a session file, newline included.
    public static func line(for segment: TranscriptSegment) throws -> Data {
        var data = try WilcoJSON.encoder().encode(segment)
        data.append(0x0A)
        return data
    }

    /// Decodes every complete line. A torn final line, left by a crash
    /// mid-write, is skipped rather than failing the whole session.
    public static func segments(in data: Data) -> [TranscriptSegment] {
        let decoder = WilcoJSON.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(TranscriptSegment.self, from: $0) }
    }
}
