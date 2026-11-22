import Foundation

/// One run-of-show marker the report looks for: a label and the phrases
/// that mark it, e.g. "House lights at half" for "house to half".
public struct MarkerLabel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var category: ShowReport.MarkerCategory
    public var name: String
    public var isEnabled: Bool
    public var phrases: [String]

    public init(
        id: UUID = UUID(),
        category: ShowReport.MarkerCategory,
        name: String,
        isEnabled: Bool = true,
        phrases: [String] = []
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.isEnabled = isEnabled
        self.phrases = phrases
    }
}

/// The marker lists a show's report uses. A show that has never edited them
/// stores none and uses ``standard``.
public struct MarkerSettings: Codable, Equatable, Sendable {
    /// Phrase markers. Within a category the first that matches a line wins,
    /// so more specific labels come first.
    public var labels: [MarkerLabel]
    /// Departments matched as "<department> go" or "go <department>".
    public var departments: [String]
    public var departmentGosEnabled: Bool
    /// The built-in "5 minutes to…" countdown, a show phase.
    public var countdownEnabled: Bool
    /// The built-in "top of the next song" pattern.
    public var songStartEnabled: Bool

    public init(
        labels: [MarkerLabel] = [],
        departments: [String] = [],
        departmentGosEnabled: Bool = true,
        countdownEnabled: Bool = true,
        songStartEnabled: Bool = true
    ) {
        self.labels = labels
        self.departments = departments
        self.departmentGosEnabled = departmentGosEnabled
        self.countdownEnabled = countdownEnabled
        self.songStartEnabled = songStartEnabled
    }

    /// Labels in one category, in match order.
    public func labels(in category: ShowReport.MarkerCategory) -> [MarkerLabel] {
        labels.filter { $0.category == category }
    }

    private enum CodingKeys: String, CodingKey {
        case labels, departments, departmentGosEnabled, countdownEnabled, songStartEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A label from a newer file with a category this build doesn't know
        // is dropped rather than failing the whole show.
        labels = try c.decodeIfPresent([LossyLabel].self, forKey: .labels)?.compactMap(\.label) ?? []
        departments = try c.decodeIfPresent([String].self, forKey: .departments) ?? []
        departmentGosEnabled = try c.decodeIfPresent(Bool.self, forKey: .departmentGosEnabled) ?? true
        countdownEnabled = try c.decodeIfPresent(Bool.self, forKey: .countdownEnabled) ?? true
        songStartEnabled = try c.decodeIfPresent(Bool.self, forKey: .songStartEnabled) ?? true
    }

    private struct LossyLabel: Decodable {
        var label: MarkerLabel?
        init(from decoder: Decoder) throws {
            label = try? MarkerLabel(from: decoder)
        }
    }

    public static let standard = MarkerSettings(
        labels: [
            .init(category: .phase, name: "Doors", phrases: ["doors are open", "open the doors", "doors open", "we have doors", "doors in"]),
            .init(category: .phase, name: "Walk-in", phrases: ["walk in music", "walk-in", "walk in is", "preshow", "pre show", "pre-show"]),
            .init(category: .phase, name: "Top of show", phrases: ["top of show", "top of the show", "top of act", "start of show"]),
            .init(category: .phase, name: "Downbeat", phrases: ["downbeat", "down beat"]),
            .init(category: .phase, name: "Blackout", phrases: ["blackout", "black out", "go to black", "we're in black"]),
            .init(category: .phase, name: "Curtain", phrases: ["curtain up", "curtain down", "the curtain"]),
            .init(category: .phase, name: "Intermission", phrases: ["intermission", "interval", "half time", "halftime"]),
            .init(category: .phase, name: "Encore", phrases: ["encore"]),
            .init(category: .phase, name: "Show clear", phrases: ["show is over", "show's over", "end of show", "that's a wrap", "thats a wrap", "all clear", "show clear"]),
            .init(category: .phase, name: "Load out", phrases: ["load out", "loadout", "load-out", "strike the", "we're striking"]),

            .init(category: .houseLights, name: "House lights out", phrases: [
                "house lights out", "house lights go out", "house lights going out", "house lights are out",
                "house lights down", "house lights to black", "kill the house", "house out", "house to black",
            ]),
            .init(category: .houseLights, name: "House lights at half", phrases: [
                "house lights half", "house lights to half", "house lights at half", "house lights to fifty",
                "house lights at fifty", "house to half", "house at half",
            ]),
            .init(category: .houseLights, name: "House lights up", phrases: [
                "house lights back", "house lights are up", "bring the house up", "house lights up",
                "house lights on", "house up",
            ]),
            .init(category: .houseLights, name: "House lights discussed", phrases: ["house lights", "house light"]),

            .init(category: .song, name: "Playback", phrases: ["playback rolling", "track is rolling", "roll playback", "music is up"]),

            .init(category: .cue, name: "Standby", phrases: ["standby", "stand by"]),
            .init(category: .cue, name: "Hold", phrases: ["hold please", "hold hold", "stop stop", "abort", "hold the cue"]),
        ],
        departments: [
            "LX", "lighting", "sound", "audio", "video", "content", "pyro", "laser", "lasers",
            "spot", "spots", "fly", "deck", "band", "screen", "screens", "graphics", "confetti",
        ]
    )
}
