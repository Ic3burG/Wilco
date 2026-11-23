import Foundation

/// Starter marker sets for the kinds of show Wilco is used on. They live in
/// the app, are read-only, and are never written to the presets folder: load
/// one, change it, and save it under your own name to keep the changes.
public extension MarkerPreset {
    static let builtIn: [MarkerPreset] = [concert, corporate, theatre]

    /// Whether this preset ships with the app rather than being saved by the user.
    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    private static let concert = MarkerPreset(
        id: UUID(uuidString: "6F1C2E0A-1C44-4B7E-9C0D-0C0A0C0E0C01")!,
        name: "Concert",
        markers: MarkerSettings.standard.changing(
            adding: [
                MarkerLabel(category: .phase, name: "Changeover", phrases: ["changeover", "change over", "turnaround"]),
                MarkerLabel(category: .phase, name: "Support set", phrases: ["support act", "support set", "opening act", "opener is on"]),
                MarkerLabel(category: .phase, name: "Headliner", phrases: ["headliner", "headline set"]),
                MarkerLabel(category: .phase, name: "Curfew", phrases: ["curfew"]),
                MarkerLabel(category: .talkback, name: "Monitor request", phrases: [
                    "in my wedge", "in my ears", "in my in ears", "in my mix", "more me", "more vocal", "more vocals",
                    "more guitar", "more keys", "more bass", "more kick", "more click", "less click", "turn me up",
                    "bring me up", "can I get more", "can I have more", "too loud in",
                ]),
                MarkerLabel(category: .talkback, name: "Soundcheck", phrases: [
                    "check one two", "check check", "line check", "sound check", "soundcheck", "mic check", "one two one two",
                ]),
                MarkerLabel(category: .talkback, name: "Run it again", phrases: [
                    "from the top", "take it from", "one more time", "run it again", "again from",
                ]),
                MarkerLabel(category: .talkback, name: "Problem", phrases: [
                    "can't hear", "cant hear", "feeding back", "feedback", "no signal", "lost my ears", "pack died",
                    "dead pack", "need batteries",
                ]),
            ],
            removing: ["Intermission", "Curtain"],
            departments: ["CO2", "haze", "strobes", "kabuki", "cryo", "lifts", "risers", "IEM"]
        )
    )

    private static let corporate = MarkerPreset(
        id: UUID(uuidString: "6F1C2E0A-1C44-4B7E-9C0D-0C0A0C0E0C02")!,
        name: "Corporate",
        markers: {
            var markers = MarkerSettings.standard.changing(
                adding: [
                    MarkerLabel(category: .phase, name: "Walk-up", phrases: ["walk up music", "walk-up", "walk up"]),
                    MarkerLabel(category: .phase, name: "VOG", phrases: ["voice of god", "vog"]),
                    MarkerLabel(category: .phase, name: "Keynote", phrases: ["keynote"]),
                    MarkerLabel(category: .phase, name: "Panel", phrases: ["panel discussion", "panelists"]),
                    MarkerLabel(category: .phase, name: "Q&A", phrases: ["q and a", "q&a", "questions from the floor"]),
                    MarkerLabel(category: .phase, name: "Awards", phrases: ["and the winner is", "award goes to", "the winner is"]),
                    MarkerLabel(category: .phase, name: "Break", phrases: ["coffee break", "lunch break", "we're on a break", "back from break"]),
                ],
                removing: ["Downbeat", "Encore", "Curtain"],
                departments: ["playback", "slides", "VT", "camera", "cameras", "stream", "records", "comfort monitors"]
            )
            markers.songStartEnabled = false
            return markers
        }()
    )

    private static let theatre = MarkerPreset(
        id: UUID(uuidString: "6F1C2E0A-1C44-4B7E-9C0D-0C0A0C0E0C03")!,
        name: "Theatre",
        markers: MarkerSettings.standard.changing(
            adding: [
                MarkerLabel(category: .phase, name: "Half", phrases: ["the half", "this is your half", "half hour call"]),
                MarkerLabel(category: .phase, name: "Quarter", phrases: ["the quarter", "this is your quarter"]),
                MarkerLabel(category: .phase, name: "Five", phrases: ["this is your five", "five minute call"]),
                MarkerLabel(category: .phase, name: "Beginners", phrases: ["beginners please", "beginners to the stage"]),
                MarkerLabel(category: .phase, name: "Places", phrases: ["places please", "places everyone"]),
                MarkerLabel(category: .phase, name: "Clearance", phrases: ["we have clearance", "front of house clearance"]),
                MarkerLabel(category: .phase, name: "Act up", phrases: ["act one", "act two", "top of act"]),
                MarkerLabel(category: .cue, name: "Warning", phrases: ["warning lx", "warning sound", "warning fly", "warning automation"]),
            ],
            removing: [],
            departments: ["automation", "flys", "rail", "revolve", "follow spots", "SM"]
        )
    )
}

extension MarkerSettings {
    /// These settings with the named labels removed, each new label placed
    /// after the last label of its category, and departments appended.
    func changing(adding labels: [MarkerLabel], removing names: Set<String>, departments: [String]) -> MarkerSettings {
        var result = self
        result.labels.removeAll { names.contains($0.name) }
        for label in labels {
            let index = result.labels.lastIndex { $0.category == label.category }.map { $0 + 1 } ?? result.labels.endIndex
            result.labels.insert(label, at: index)
        }
        result.departments += departments
        return result
    }
}
