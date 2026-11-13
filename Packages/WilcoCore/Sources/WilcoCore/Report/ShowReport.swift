import Foundation

/// A post-show breakdown of one capture session.
public struct ShowReport: Sendable {
    public enum MarkerCategory: String, CaseIterable, Sendable {
        case phase, houseLights, song, cue, department

        public var title: String {
            switch self {
            case .phase: "Show phases"
            case .houseLights: "House lights"
            case .song: "Songs"
            case .cue: "Cue calls"
            case .department: "Department gos"
            }
        }

        /// The colour of this kind of moment, in the window and the export.
        public var tint: ChannelTint {
            switch self {
            case .phase: .indigo
            case .houseLights: .orange
            case .song: .pink
            case .cue: .green
            case .department: .teal
            }
        }
    }

    public struct Term: Equatable, Sendable {
        public var word: String
        public var count: Int
    }

    public struct Channel: Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var symbol: String
        public var tint: ChannelTint
        public var messages: Int
        public var words: Int
        /// This channel's part of all the session's messages, 0...1.
        public var share: Double
        /// Mean recognition confidence of the lines that report one.
        public var meanConfidence: Double?
        /// Lines recognised with less than `ShowReport.unclearBelow` confidence.
        public var unclear: Int
        /// Start of the ten minutes with the most messages on this channel.
        public var busiestStart: Double?
        public var busiestCount: Int
        /// Most-used words, ignoring common chatter.
        public var topTerms: [Term]
    }

    /// A sidebar group as a filter chip. Transcripts record channels, not
    /// groups, so this is the show's grouping now, not during the session.
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var symbol: String
        /// Members that spoke this session, in sidebar order.
        public var channelIDs: [UUID]

        public init(id: UUID, name: String, symbol: String, channelIDs: [UUID]) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.channelIDs = channelIDs
        }

        /// On when every one of its channels is in the filter.
        public func isOn(in filter: Set<UUID>) -> Bool {
            !channelIDs.isEmpty && Set(channelIDs).isSubset(of: filter)
        }

        /// Clicking the chip: all its channels off if it was on, else all on.
        public func toggled(_ filter: Set<UUID>) -> Set<UUID> {
            isOn(in: filter) ? filter.subtracting(channelIDs) : filter.union(channelIDs)
        }
    }

    /// Confidence below which a line counts as unclear (0.2.0's threshold).
    public static let unclearBelow = 0.5
    /// Length of the window behind "busiest".
    public static let busiestWindow: Double = 600

    public struct Message: Identifiable, Sendable {
        public var id: UUID
        /// Seconds since the session started.
        public var elapsed: Double
        public var date: Date
        public var channelID: UUID
        public var channelName: String
        public var tint: ChannelTint
        public var text: String
        public var confidence: Double?
    }

    public struct Marker: Identifiable, Sendable {
        public var id = UUID()
        public var elapsed: Double
        public var date: Date
        public var category: MarkerCategory
        public var label: String
        public var channelID: UUID
        public var channelName: String
        public var tint: ChannelTint
        public var text: String
        public var matched: String
        public var messageID: UUID
        /// The same call repeated on the same channel within a minute counts once.
        public var repeats: Int
    }

    /// Message counts per channel over one slice of the session.
    public struct Bucket: Sendable {
        public var start: Double
        public var counts: [UUID: Int]
    }

    public var showName: String
    public var sessionStart: Date
    public var duration: Double
    public var totalMessages: Int
    public var channels: [Channel]
    /// The show's current sidebar groups that had someone speak.
    public var groups: [Group] = []
    public var markers: [Marker]
    public var messages: [Message]
    public var buckets: [Bucket]
    public var bucketSeconds: Double
    public var sourceName: String
    public var generated: Date
}

public enum ShowReportBuilder {
    /// Repeats of a call further apart than this are separate markers.
    static let repeatWindow: Double = 60

    public static func build(segments: [TranscriptSegment], show: ShowDocument, sourceName: String, generated: Date) -> ShowReport {
        let lines = segments.filter(\.isFinal).sorted { $0.sessionOffset < $1.sessionOffset }
        let first = lines.first
        let sessionStart = first.map { $0.timestamp.addingTimeInterval(-$0.sessionOffset) } ?? generated
        let lastOffset = lines.last?.sessionOffset ?? 0
        let duration = lastOffset - (first?.sessionOffset ?? 0)

        func channel(_ id: UUID) -> (name: String, symbol: String, tint: ChannelTint) {
            guard let channel = show.channel(id: id) else { return ("Unknown channel", "questionmark", .gray) }
            return (channel.name, channel.symbol, channel.tint)
        }

        var messages: [ShowReport.Message] = []
        var markers: [ShowReport.Marker] = []
        var lastSeen: [String: (index: Int, elapsed: Double)] = [:]
        var words: [UUID: Int] = [:]
        var termCounts: [UUID: [String: Int]] = [:]
        var messageCounts: [UUID: Int] = [:]
        var confidences: [UUID: [Double]] = [:]
        var offsets: [UUID: [Double]] = [:]

        for line in lines {
            let info = channel(line.channelID)
            messages.append(ShowReport.Message(
                id: line.id, elapsed: line.sessionOffset, date: line.timestamp, channelID: line.channelID,
                channelName: info.name, tint: info.tint, text: line.text, confidence: line.confidence
            ))
            messageCounts[line.channelID, default: 0] += 1
            offsets[line.channelID, default: []].append(line.sessionOffset)
            if let confidence = line.confidence { confidences[line.channelID, default: []].append(confidence) }

            words[line.channelID, default: 0] += line.text.split(whereSeparator: \.isWhitespace).count
            for term in terms(in: line.text) {
                termCounts[line.channelID, default: [:]][term, default: 0] += 1
            }

            for detection in MarkerDetector.detect(in: line.text) {
                let key = "\(line.channelID)|\(detection.category.rawValue)|\(detection.label)"
                if let seen = lastSeen[key], line.sessionOffset - seen.elapsed <= repeatWindow {
                    markers[seen.index].repeats += 1
                    lastSeen[key] = (seen.index, line.sessionOffset)
                    continue
                }
                lastSeen[key] = (markers.count, line.sessionOffset)
                markers.append(ShowReport.Marker(
                    elapsed: line.sessionOffset, date: line.timestamp, category: detection.category,
                    label: detection.label, channelID: line.channelID, channelName: info.name, tint: info.tint,
                    text: line.text, matched: detection.matched, messageID: line.id, repeats: 1
                ))
            }
        }

        // Channels in sidebar order, then any no longer in the show.
        let known = show.channels.map(\.id).filter { messageCounts[$0] != nil }
        let unknown = Set(messageCounts.keys).subtracting(known).sorted { $0.uuidString < $1.uuidString }
        let channels = (known + unknown).map { id in
            let info = channel(id)
            let terms = (termCounts[id] ?? [:])
                .map { ShowReport.Term(word: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.word) > ($1.count, $0.word) }
            let scores = confidences[id] ?? []
            let busiest = busiestWindow(in: offsets[id] ?? [])
            return ShowReport.Channel(
                id: id, name: info.name, symbol: info.symbol, tint: info.tint,
                messages: messageCounts[id] ?? 0, words: words[id] ?? 0,
                share: lines.isEmpty ? 0 : Double(messageCounts[id] ?? 0) / Double(lines.count),
                meanConfidence: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                unclear: scores.count { $0 < ShowReport.unclearBelow },
                busiestStart: busiest?.start, busiestCount: busiest?.count ?? 0,
                topTerms: Array(terms.prefix(8))
            )
        }

        // Whole minutes, at most about 120 columns.
        let bucketSeconds = max(1, (duration / 60 / 120).rounded(.up)) * 60
        var buckets = (0...Int(lastOffset / bucketSeconds)).map {
            ShowReport.Bucket(start: Double($0) * bucketSeconds, counts: [:])
        }
        for line in lines {
            buckets[Int(line.sessionOffset / bucketSeconds)].counts[line.channelID, default: 0] += 1
        }

        let groups = show.groups.compactMap { group -> ShowReport.Group? in
            let spoke = show.channels(inGroup: group.id).map(\.id).filter { messageCounts[$0] != nil }
            return spoke.isEmpty ? nil : ShowReport.Group(id: group.id, name: group.name, symbol: group.symbol, channelIDs: spoke)
        }

        return ShowReport(
            showName: show.name, sessionStart: sessionStart, duration: duration, totalMessages: lines.count,
            channels: channels, groups: groups, markers: markers, messages: messages, buckets: buckets,
            bucketSeconds: bucketSeconds, sourceName: sourceName, generated: generated
        )
    }

    /// The ten minutes, starting at a line, holding the most lines; the
    /// earliest wins a tie. `offsets` must be in order.
    static func busiestWindow(in offsets: [Double]) -> (start: Double, count: Int)? {
        var best: (start: Double, count: Int)?
        var end = 0
        for (index, start) in offsets.enumerated() {
            end = max(end, index)
            while end < offsets.count && offsets[end] < start + ShowReport.busiestWindow { end += 1 }
            let count = end - index
            if count > (best?.count ?? 0) { best = (start, count) }
        }
        return best
    }

    /// Words worth counting: three letters or more, not just digits, not
    /// common chatter. Apostrophes stay, so "he's" and "let's" read as said.
    static func terms(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
            .filter { word in
                let bare = word.replacingOccurrences(of: "'", with: "")
                return bare.count >= 3 && !bare.allSatisfy(\.isNumber)
                    && !stopWords.contains(word) && !stopWords.contains(bare)
            }
    }

    /// Chatter that says nothing about what a channel was for (0.2.0's list).
    static let stopWords: Set<String> = [
        "the", "and", "you", "that", "this", "with", "for", "are", "was", "but", "not", "have", "just", "get",
        "got", "gonna", "going", "yeah", "yes", "okay", "all", "right", "like", "know", "what", "were", "im",
        "its", "dont", "can", "will", "one", "out", "there", "here", "your", "they", "them", "then", "now",
        "put", "let", "look", "see", "back", "down", "over", "want", "need", "good", "well", "some", "how",
        "who", "why", "did", "does", "doing", "been", "from", "into", "about", "think", "really", "still",
        "off", "very", "much", "any", "his", "her", "hers", "him", "she", "our", "ours", "has", "had",
        "would", "could", "should", "thing", "things", "actually", "because", "little", "make", "made",
        "take", "come", "coming", "say", "said", "says",
    ]
}

public enum ShowReportSearch {
    /// A parsed query: loose words plus "quoted phrases".
    public struct Query: Equatable, Sendable {
        /// Each must appear somewhere in the line, even inside a longer word.
        public var words: [String]
        /// Each must appear as whole words, in order.
        public var phrases: [String]

        public var isEmpty: Bool { words.isEmpty && phrases.isEmpty }
        /// Everything worth highlighting in a matching line.
        public var highlightTerms: [String] { phrases + words }

        public init(_ text: String) {
            words = []
            phrases = []
            var inQuote = false
            for (index, part) in text.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
                inQuote = index % 2 == 1
                if inQuote {
                    let phrase = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !phrase.isEmpty { phrases.append(phrase.lowercased()) }
                } else {
                    words += part.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                }
            }
        }

        public func matches(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return words.allSatisfy { lowered.contains($0) }
                && phrases.allSatisfy { !PhraseLocator.ranges(of: $0, in: text).isEmpty }
        }
    }

    /// Messages matching `query` (see `Query`), optionally limited to
    /// `channels`. An empty query matches everything.
    public static func messages(in report: ShowReport, matching query: String, channels: Set<UUID> = []) -> [ShowReport.Message] {
        let query = Query(query)
        return report.messages.filter { message in
            guard channels.isEmpty || channels.contains(message.channelID) else { return false }
            return query.isEmpty || query.matches(message.text)
        }
    }
}

/// Finds a phrase in a line the way people say it: any case, and with
/// spaces, hyphens or nothing between its words, so "stand by" finds
/// "Stand-by" and "standby", and "standby" finds "Stand by" (speech
/// engines split and join words freely). Only whole words match.
public enum PhraseLocator {
    public static func ranges(of phrase: String, in text: String) -> [Range<String.Index>] {
        let words = phrase.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        guard !words.isEmpty else { return [] }
        // A separator may fall anywhere inside the phrase, not just between its words.
        let letters = words.joined().map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}])"
            + letters.joined(separator: "[\\s\\-]*")
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }
}
