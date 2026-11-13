import Foundation

/// Finds run-of-show moments in comms: show phases, house lights, songs,
/// cue calls and department gos. Phrase lists follow 0.2.0.
public enum MarkerDetector {
    public struct Detection: Equatable, Sendable {
        public var category: ShowReport.MarkerCategory
        public var label: String
        /// What was actually said.
        public var matched: String
    }

    private enum Matcher {
        /// Each phrase with its words, split once up front.
        case phrases([(phrase: String, words: [String])])
        /// The label is taken from what the pattern matched when the rule has none.
        case pattern(NSRegularExpression)
    }

    private struct Rule {
        var category: ShowReport.MarkerCategory
        var label: String?
        var matcher: Matcher
    }

    /// At most one marker per category per line: the first rule that matches,
    /// so more specific rules come first within a category.
    public static func detect(in text: String) -> [Detection] {
        let words = KeywordMatcher.tokens(text)
        return ShowReport.MarkerCategory.allCases.compactMap { category in
            for rule in rules where rule.category == category {
                if let detection = match(rule, in: text, words: words) { return detection }
            }
            return nil
        }
    }

    private static func match(_ rule: Rule, in text: String, words: [String]) -> Detection? {
        switch rule.matcher {
        case .phrases(let phrases):
            guard let phrase = KeywordMatcher.firstMatch(of: phrases, in: words) else { return nil }
            return Detection(category: rule.category, label: rule.label ?? phrase, matched: phrase)
        case .pattern(let expression):
            guard let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(found.range, in: text) else { return nil }
            let matched = String(text[range])
            return Detection(category: rule.category, label: rule.label ?? matched.prefix(1).uppercased() + matched.dropFirst(), matched: matched)
        }
    }

    private static func phrases(_ list: [String]) -> Matcher {
        .phrases(list.map { ($0, KeywordMatcher.tokens($0)) })
    }

    private static func pattern(_ source: String) -> Matcher {
        // The patterns are fixed and known to compile.
        .pattern(try! NSRegularExpression(pattern: source, options: [.caseInsensitive]))
    }

    private static let rules: [Rule] = [
        // Show phases
        Rule(category: .phase, label: "Doors", matcher: phrases(["doors are open", "open the doors", "doors open", "we have doors", "doors in"])),
        Rule(category: .phase, label: "Walk-in", matcher: phrases(["walk in music", "walk-in", "walk in is", "preshow", "pre show", "pre-show"])),
        Rule(category: .phase, label: "Top of show", matcher: phrases(["top of show", "top of the show", "top of act", "start of show"])),
        Rule(category: .phase, label: "Downbeat", matcher: phrases(["downbeat", "down beat"])),
        Rule(category: .phase, label: "Blackout", matcher: phrases(["blackout", "black out", "go to black", "we're in black"])),
        Rule(category: .phase, label: "Curtain", matcher: phrases(["curtain up", "curtain down", "the curtain"])),
        Rule(category: .phase, label: "Intermission", matcher: phrases(["intermission", "interval", "half time", "halftime"])),
        Rule(category: .phase, label: "Encore", matcher: phrases(["encore"])),
        Rule(category: .phase, label: "Show clear", matcher: phrases(["show is over", "show's over", "end of show", "that's a wrap", "thats a wrap", "all clear", "show clear"])),
        Rule(category: .phase, label: "Load out", matcher: phrases(["load out", "loadout", "load-out", "strike the", "we're striking"])),
        Rule(category: .phase, label: "Countdown", matcher: pattern(#"\b(?:we(?:'| a)re )?(?:t minus |at )?\d{1,3} minutes? (?:to|from|out|until)\b"#)),

        // House lights, most specific first
        Rule(category: .houseLights, label: "House lights out", matcher: phrases([
            "house lights out", "house lights go out", "house lights going out", "house lights are out",
            "house lights down", "house lights to black", "kill the house", "house out", "house to black",
        ])),
        Rule(category: .houseLights, label: "House lights at half", matcher: phrases([
            "house lights half", "house lights to half", "house lights at half", "house lights to fifty",
            "house lights at fifty", "house to half", "house at half",
        ])),
        Rule(category: .houseLights, label: "House lights up", matcher: phrases([
            "house lights back", "house lights are up", "bring the house up", "house lights up",
            "house lights on", "house up",
        ])),
        Rule(category: .houseLights, label: "House lights discussed", matcher: phrases(["house lights", "house light"])),

        // Songs
        Rule(category: .song, label: "Song start", matcher: pattern(
            #"\b(?:top of (?:this|that|the next) (?:song|tune|number)|(?:song|tune|track) (?:is )?(?:starting|starts|started)|going into (?:the )?(?:next )?(?:song|tune|track)|next (?:song|tune|track) (?:is|up)|(?:this|that) (?:song|tune) (?:is )?(?:next|now)|playback (?:is )?(?:rolling|running|going))\b"#
        )),
        Rule(category: .song, label: "Playback", matcher: phrases(["playback rolling", "track is rolling", "roll playback", "music is up"])),

        // Cue calls
        Rule(category: .cue, label: "Standby", matcher: phrases(["standby", "stand by"])),
        Rule(category: .cue, label: "Hold", matcher: phrases(["hold please", "hold hold", "stop stop", "abort", "hold the cue"])),

        // Department gos: the label is what was said, e.g. "Pyro go"
        Rule(category: .department, label: nil, matcher: pattern(
            #"\b(?:(?:lx|lighting|sound|audio|video|content|pyro|lasers?|spots?|fly|deck|band|screens?|graphics|confetti|cue \d+)\s+go|go\s+(?:lx|lighting|sound|audio|video|content|pyro|lasers?|spots?|fly|deck|cue \d+))\b"#
        )),
    ]
}
