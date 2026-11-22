import Foundation

/// Finds run-of-show moments in comms: show phases, house lights, songs,
/// cue calls and department gos, using a show's ``MarkerSettings``.
public enum MarkerDetector {
    public struct Detection: Equatable, Sendable {
        public var category: ShowReport.MarkerCategory
        public var label: String
        /// What was actually said.
        public var matched: String
    }

    /// At most one marker per category per line: the first that matches, so
    /// more specific labels come first within a category.
    public static func detect(in text: String, settings: MarkerSettings = .standard) -> [Detection] {
        let words = KeywordMatcher.tokens(text)
        return ShowReport.MarkerCategory.allCases.compactMap { category in
            switch category {
            case .phase:
                phrase(.phase, settings, words)
                    ?? (settings.countdownEnabled ? pattern(countdown, label: "Countdown", .phase, in: text) : nil)
            case .song:
                (settings.songStartEnabled ? pattern(songStart, label: "Song start", .song, in: text) : nil)
                    ?? phrase(.song, settings, words)
            case .houseLights, .cue:
                phrase(category, settings, words)
            case .department:
                settings.departmentGosEnabled ? departmentGo(settings.departments, words) : nil
            }
        }
    }

    private static func phrase(_ category: ShowReport.MarkerCategory, _ settings: MarkerSettings, _ words: [String]) -> Detection? {
        for label in settings.labels where label.category == category && label.isEnabled {
            let phrases = label.phrases.map { ($0, KeywordMatcher.tokens($0)) }
            if let phrase = KeywordMatcher.firstMatch(of: phrases, in: words) {
                return Detection(category: category, label: label.name, matched: phrase)
            }
        }
        return nil
    }

    private static func pattern(_ expression: NSRegularExpression, label: String, _ category: ShowReport.MarkerCategory, in text: String) -> Detection? {
        guard let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range, in: text) else { return nil }
        return Detection(category: category, label: label, matched: String(text[range]))
    }

    /// "<department> go" or "go <department>" as consecutive words, or
    /// "cue <number> go" / "go cue <number>". Words are matched exactly, not
    /// joined, so "pyrogo" and "good to go" don't count. The call said first
    /// wins ("go pyro, go lasers" is "Go pyro"), then the longest, so "follow
    /// spot go" beats "spot go" whatever the list order.
    private static func departmentGo(_ departments: [String], _ words: [String]) -> Detection? {
        var best: (start: Int, length: Int, label: String)?
        func consider(_ run: [String], label: @autoclosure () -> String) {
            guard let start = firstIndex(of: run, in: words) else { return }
            if let current = best, current.start < start || (current.start == start && current.length >= run.count) { return }
            best = (start, run.count, label())
        }
        for department in departments {
            let name = department.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = KeywordMatcher.tokens(name)
            guard !tokens.isEmpty else { continue }
            consider(tokens + ["go"], label: capitalised(name) + " go")
            consider(["go"] + tokens, label: "Go " + name)
        }
        for index in words.indices where words[index] == "cue" && index + 1 < words.count {
            let number = words[index + 1]
            guard number.allSatisfy(\.isNumber) else { continue }
            consider(["cue", number, "go"], label: "Cue \(number) go")
            consider(["go", "cue", number], label: "Go cue \(number)")
        }
        return best.map { Detection(category: .department, label: $0.label, matched: $0.label) }
    }

    private static func firstIndex(of run: [String], in words: [String]) -> Int? {
        guard run.count <= words.count else { return nil }
        return (0...(words.count - run.count)).first { Array(words[$0..<$0 + run.count]) == run }
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // The patterns are fixed and known to compile.
    private static let countdown = try! NSRegularExpression(
        pattern: #"\b(?:we(?:'| a)re )?(?:t minus |at )?\d{1,3} minutes? (?:to|from|out|until)\b"#,
        options: [.caseInsensitive]
    )

    private static let songStart = try! NSRegularExpression(
        pattern: #"\b(?:top of (?:this|that|the next) (?:song|tune|number)|(?:song|tune|track) (?:is )?(?:starting|starts|started)|going into (?:the )?(?:next )?(?:song|tune|track)|next (?:song|tune|track) (?:is|up)|(?:this|that) (?:song|tune) (?:is )?(?:next|now)|playback (?:is )?(?:rolling|running|going))\b"#,
        options: [.caseInsensitive]
    )
}
