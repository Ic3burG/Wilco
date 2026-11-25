import Foundation

/// A fixed, hand-written list of the settings people look for, so the
/// Settings search can say which page holds each one. It is app text only,
/// never anything from a show, so nothing a show contains can appear in
/// search results.
public enum SettingsIndex {
    public struct Entry: Hashable, Sendable {
        public var title: String
        public var keywords: [String]
        public var page: SettingsPage

        public init(_ title: String, _ page: SettingsPage, keywords: [String] = []) {
            self.title = title
            self.keywords = keywords
            self.page = page
        }
    }

    public static let entries: [Entry] = [
        // Audio
        Entry("Show Device", .audio, keywords: ["audio", "interface", "input", "microphone"]),
        Entry("Refresh Devices", .audio, keywords: ["audio", "interface", "rescan"]),
        Entry("Capture Health", .audio, keywords: ["reconnect", "driver", "stall", "state"]),
        // Speech
        Entry("Engine for New Channels", .speech, keywords: ["parakeet", "whisper", "apple", "default"]),
        Entry("Language for New Channels", .speech, keywords: ["english", "locale", "default"]),
        Entry("Whisper Model", .speech, keywords: ["open", "model", "size"]),
        Entry("Vocabulary", .speech, keywords: ["global", "terms", "words", "names"]),
        Entry("Voice Changes", .speech, keywords: ["speaker", "exchange", "threshold"]),
        Entry("Telling Voices Apart", .speech, keywords: ["stricter", "looser", "speaker"]),
        Entry("New Exchange Gap", .speech, keywords: ["seconds", "voice"]),
        // Destinations
        Entry("OSC Destinations", .destinations, keywords: ["osc", "console", "host", "port", "udp", "tcp", "slip"]),
        Entry("Add Destination", .destinations, keywords: ["osc", "console"]),
        // Rules & Highlights
        Entry("Rules", .rules, keywords: ["automation", "trigger", "cue", "phrase", "action"]),
        Entry("Highlights", .rules, keywords: ["colour", "color", "words", "highlight"]),
        Entry("OSC Message Action", .rules, keywords: ["osc", "send"]),
        Entry("MIDI Message Action", .rules, keywords: ["midi", "program", "note"]),
        Entry("Webhook Action", .rules, keywords: ["http", "url"]),
        Entry("Notification Action", .rules, keywords: ["alert", "notify"]),
        Entry("Mark Cue Point", .rules, keywords: ["cue", "marker"]),
        Entry("Cooldown", .rules, keywords: ["repeat", "seconds"]),
        Entry("Test Rule", .rules, keywords: ["try", "fire"]),
        // Markers
        Entry("Report Markers", .markers, keywords: ["labels", "run", "show", "report"]),
        Entry("Marker Presets", .markers, keywords: ["preset", "restore", "defaults"]),
        Entry("Department Gos", .markers, keywords: ["departments", "go", "rigging"]),
        // General
        Entry("Keep the Display Awake", .general, keywords: ["sleep", "screen", "app nap", "awake", "capture"]),
        Entry("Open at Login", .general, keywords: ["login items", "startup", "launch", "boot"]),
        Entry("Start Capture When Wilco Opens", .general, keywords: ["automatic", "launch", "power cut", "restart"]),
        Entry("Ask Before Quitting While Capturing", .general, keywords: ["quit", "capture", "confirm"]),
        Entry("Ask to Save on Quit", .general, keywords: ["configuration", "quit", "save"]),
        Entry("Keep Sessions", .general, keywords: ["transcripts", "delete", "trash", "old", "retention", "disk"]),
        Entry("Transcripts Folder", .general, keywords: ["finder", "size", "sessions", "disk"]),
        Entry("Dismissed Suggestions", .general, keywords: ["review", "findings", "reset", "hidden"]),
        // Appearance
        Entry("Theme", .appearance, keywords: ["dark", "light", "mode", "appearance"]),
        Entry("Text Size", .appearance, keywords: ["font", "bigger", "smaller"]),
        Entry("Show Timecode", .appearance, keywords: ["time", "transcript"]),
        Entry("Auto-scroll to Newest", .appearance, keywords: ["follow", "live", "scroll"]),
        Entry("Newest Line First", .appearance, keywords: ["order", "reverse", "transcript"]),
        // Speech Models
        Entry("Whisper Download", .speechModels, keywords: ["download", "model", "install"]),
        Entry("Parakeet Model", .speechModels, keywords: ["download", "install", "vocabulary"]),
        Entry("Voice Model", .speechModels, keywords: ["download", "install", "voice", "speaker"]),
        Entry("Apple Speech Models", .speechModels, keywords: ["download", "install", "language", "long-form", "dictation"]),
        Entry("Learning Downloads", .speechModels, keywords: ["parakeet", "ultra", "whisper", "large", "voice", "grouping", "sortformer"]),
        // Learning
        Entry("Keep Audio Clips", .learning, keywords: ["clips", "learn", "record"]),
        Entry("Delete All Clips", .learning, keywords: ["clips", "space", "disk"]),
        Entry("Voters", .learning, keywords: ["labelling", "labeling", "agree"]),
    ]

    /// Entries whose title or keywords contain a word starting with each word
    /// of `query`, ignoring case and accents, in index order. A query with no
    /// letters or digits finds nothing.
    public static func search(_ query: String) -> [Entry] {
        let wanted = words(in: query)
        guard !wanted.isEmpty else { return [] }
        return entries.filter { entry in
            let have = words(in: ([entry.title] + entry.keywords).joined(separator: " "))
            return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
        }
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
