import Foundation

/// One channel's measurements over a session, summarised from its
/// `.diagnostics` rows.
public struct ChannelDiagnostics: Sendable {
    public var minutes: Int
    /// Minutes with at least `ReviewThresholds.soundMinuteSeconds` of sound.
    public var soundMinutes: Int
    /// Seconds above the sound floor across every minute.
    public var soundSeconds: Double
    /// Highest sample over every row; nil when no row measured one.
    public var peak: Double?
    /// Median of the per-minute RMS over sound minutes.
    public var medianRMS: Double?
    /// Share of sound minutes with any clipped sample.
    public var clippedSoundMinuteShare: Double
    public var droppedSeconds: Double
    /// Minutes in which audio went missing: a full minute that read too
    /// little, or a gap between rows that no stop or mute explains.
    public var lostMinutes: [Int]
    /// Sound minutes the classifier answered for.
    public var classifiedSoundMinutes: Int
    public var speechMinutes: Int
    public var musicMinutes: Int
    /// Utterances cut at the limit; nil for engines that don't report it.
    public var cuts: Int?
}

/// The measurements of a whole session, by channel.
public struct SessionDiagnostics: Sendable {
    public var channels: [UUID: ChannelDiagnostics]

    public static func make(_ rows: [ChannelMinute]) -> SessionDiagnostics {
        var byChannel: [UUID: [Int: ChannelMinute]] = [:]
        for row in rows {
            if var existing = byChannel[row.channel, default: [:]][row.minute] {
                existing.merge(row)
                byChannel[row.channel]?[row.minute] = existing
            } else {
                byChannel[row.channel, default: [:]][row.minute] = row
            }
        }
        return SessionDiagnostics(channels: byChannel.mapValues { summarise($0.values.sorted { $0.minute < $1.minute }) })
    }

    /// Nil when the session has no `.diagnostics` file or it holds no rows.
    public static func load(forTranscript transcript: URL) -> SessionDiagnostics? {
        guard let data = try? Data(contentsOf: DiagnosticsFile.url(forTranscript: transcript)) else { return nil }
        let rows = DiagnosticsFile.rows(in: data)
        return rows.isEmpty ? nil : make(rows)
    }

    /// `rows` are one channel's, one per minute, in minute order.
    private static func summarise(_ rows: [ChannelMinute]) -> ChannelDiagnostics {
        let sound = rows.filter { $0.sound >= ReviewThresholds.soundMinuteSeconds }
        let clipped = sound.filter { $0.clipped > 0 }.count
        let classified = sound.filter { $0.classified != nil }
        let speech = classified.filter { ($0.classified?.speech ?? 0) >= 0.5 }.count
        let music = classified.filter { row in
            guard let shares = row.classified else { return false }
            return max(shares.music, shares.singing) > shares.speech
        }.count
        let cuts = rows.compactMap(\.cuts)
        return ChannelDiagnostics(
            minutes: rows.count,
            soundMinutes: sound.count,
            soundSeconds: rows.reduce(0) { $0 + $1.sound },
            peak: rows.compactMap(\.peak).max(),
            medianRMS: SessionStats.median(sound.compactMap(\.rms)),
            clippedSoundMinuteShare: sound.isEmpty ? 0 : Double(clipped) / Double(sound.count),
            droppedSeconds: rows.reduce(0) { $0 + $1.droppedSeconds },
            lostMinutes: lostMinutes(rows),
            classifiedSoundMinutes: classified.count,
            speechMinutes: speech,
            musicMinutes: music,
            cuts: cuts.isEmpty ? nil : cuts.reduce(0, +)
        )
    }

    /// A channel's first and last rows are partial by construction, so only
    /// full rows count as short. A gap after a partial row is a stop or mute;
    /// a gap after a full row is an engine that never answered.
    private static func lostMinutes(_ rows: [ChannelMinute]) -> [Int] {
        var lost: [Int] = []
        for (index, row) in rows.enumerated() {
            guard row.partial != true else { continue }
            if row.audio < ReviewThresholds.lostMinuteAudio { lost.append(row.minute) }
            if index + 1 < rows.count, rows[index + 1].minute > row.minute + 1 {
                lost.append(contentsOf: (row.minute + 1)..<rows[index + 1].minute)
            }
        }
        return lost
    }
}
