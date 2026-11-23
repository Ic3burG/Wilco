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

    /// A show's marker settings with every phrase and department already
    /// split into words, so a report splits them once rather than per line.
    public struct Prepared: Sendable {
        struct PhraseLabel: Sendable {
            var category: ShowReport.MarkerCategory
            var name: String
            var phrases: [(phrase: String, words: [String])]
        }

        var labels: [PhraseLabel]
        /// Each department's "X go" and "go X" word runs with their labels.
        var departmentRuns: [(words: [String], label: String)]
        /// Names matched with a cue number: "LX 47 go", "go sound 12". "Cue"
        /// is always here, even with no departments listed.
        var numberedNames: [(name: String, words: [String])]
        var departmentGosEnabled: Bool
        var countdownEnabled: Bool
        var songStartEnabled: Bool

        public init(_ settings: MarkerSettings) {
            labels = settings.labels.filter(\.isEnabled).map { label in
                let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return PhraseLabel(category: label.category, name: name.isEmpty ? "Untitled Label" : name,
                            phrases: label.phrases.map { ($0, KeywordMatcher.tokens($0)) })
            }
            departmentRuns = settings.departments.flatMap { department -> [(words: [String], label: String)] in
                let name = department.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = KeywordMatcher.tokens(name)
                guard !words.isEmpty else { return [] }
                return [(words + ["go"], MarkerDetector.capitalised(name) + " go"), (["go"] + words, "Go " + name)]
            }
            numberedNames = [("cue", ["cue"])] + settings.departments.compactMap { department in
                let name = department.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = KeywordMatcher.tokens(name)
                return words.isEmpty ? nil : (name, words)
            }
            departmentGosEnabled = settings.departmentGosEnabled
            countdownEnabled = settings.countdownEnabled
            songStartEnabled = settings.songStartEnabled
        }
    }

    /// At most one marker per category per line: the first that matches, so
    /// more specific labels come first within a category.
    public static func detect(in text: String, settings: MarkerSettings = .standard) -> [Detection] {
        detect(in: text, prepared: Prepared(settings))
    }

    public static func detect(in text: String, prepared: Prepared) -> [Detection] {
        let words = KeywordMatcher.tokens(text)
        return ShowReport.MarkerCategory.allCases.compactMap { category in
            switch category {
            case .phase:
                phrase(.phase, prepared, words)
                    ?? (prepared.countdownEnabled ? pattern(countdown, label: "Countdown", .phase, in: text) : nil)
            case .song:
                (prepared.songStartEnabled ? pattern(songStart, label: "Song start", .song, in: text) : nil)
                    ?? phrase(.song, prepared, words)
            case .houseLights, .cue, .talkback:
                phrase(category, prepared, words)
            case .department:
                prepared.departmentGosEnabled ? departmentGo(prepared, words) : nil
            }
        }
    }

    private static func phrase(_ category: ShowReport.MarkerCategory, _ prepared: Prepared, _ words: [String]) -> Detection? {
        for label in prepared.labels where label.category == category {
            if let phrase = KeywordMatcher.firstMatch(of: label.phrases, in: words) {
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

    /// "<department> go" or "go <department>" as consecutive words, or with a
    /// cue number: "LX 47 go", "go sound 12", "cue 47 go". Words are matched exactly, not
    /// joined, so "pyrogo" and "good to go" don't count. The call said first
    /// wins ("go pyro, go lasers" is "Go pyro"), then the longest, so "follow
    /// spot go" beats "spot go" whatever the list order.
    private static func departmentGo(_ prepared: Prepared, _ words: [String]) -> Detection? {
        // Every department call has "go" in it; most lines don't.
        guard words.contains("go") else { return nil }
        var best: (start: Int, length: Int, label: String)?
        func consider(_ run: [String], label: @autoclosure () -> String) {
            guard let start = firstIndex(of: run, in: words) else { return }
            if let current = best, current.start < start || (current.start == start && current.length >= run.count) { return }
            best = (start, run.count, label())
        }
        for run in prepared.departmentRuns {
            consider(run.words, label: run.label)
        }
        // "<name> <number> go" and "go <name> <number>", wherever the name is said.
        for (name, tokens) in prepared.numberedNames {
            var from = 0
            while let at = firstIndex(of: tokens, in: words, from: from) {
                from = at + 1
                let after = at + tokens.count
                guard after < words.count, words[after].allSatisfy(\.isNumber) else { continue }
                let number = words[after]
                if after + 1 < words.count, words[after + 1] == "go" {
                    consider(tokens + [number, "go"], label: capitalised(name) + " \(number) go")
                }
                if at > 0, words[at - 1] == "go" {
                    consider(["go"] + tokens + [number], label: "Go \(name) \(number)")
                }
            }
        }
        return best.map { Detection(category: .department, label: $0.label, matched: $0.label) }
    }

    private static func firstIndex(of run: [String], in words: [String], from: Int = 0) -> Int? {
        guard run.count <= words.count, from <= words.count - run.count else { return nil }
        return (from...(words.count - run.count)).first { words[$0..<$0 + run.count].elementsEqual(run) }
    }

    fileprivate static func capitalised(_ text: String) -> String {
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
