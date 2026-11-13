import Foundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt, vtt

    public var fileExtension: String { rawValue }
}

/// Subtitles for a session, timed from the start of capture, so the comms
/// can be laid over a recording of the show.
public enum SubtitleExport {
    /// Each line stays up until the next begins, for at most this long.
    static let maximumCueLength: Double = 4

    public static func render(_ report: ShowReport, format: SubtitleFormat) -> String {
        var output = format == .vtt ? "WEBVTT\n\n" : ""
        for (index, message) in report.messages.enumerated() {
            let start = message.elapsed
            let next = index + 1 < report.messages.count ? report.messages[index + 1].elapsed : .infinity
            let end = max(start + 0.5, min(next, start + maximumCueLength))
            var text = "\(message.channelName): \(message.text)"
            if format == .vtt {
                text = text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            if format == .srt { output += "\(index + 1)\n" }
            output += "\(timestamp(start, format)) --> \(timestamp(end, format))\n\(text)\n\n"
        }
        return output
    }

    /// `HH:MM:SS,mmm` for SRT, `HH:MM:SS.mmm` for WebVTT.
    static func timestamp(_ seconds: Double, _ format: SubtitleFormat) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let separator = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d",
                      milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60,
                      separator, milliseconds % 1000)
    }
}
