import Foundation
import Testing
@testable import WilcoCore

@Suite("Configuration rules")
struct ConfigurationRulesTests {
    typealias Rules = ConfigurationRules

    @Test func statusCases() {
        var saved = ShowDocument(name: "Arena")
        saved.addChannel()
        var working = saved

        #expect(Rules.status(working: working, saved: nil) == .notSaved)
        #expect(Rules.status(working: working, saved: saved) == .saved)
        working.channels[0].name = "Changed"
        #expect(Rules.status(working: working, saved: saved) == .edited)
        working.channels[0].name = saved.channels[0].name
        #expect(Rules.status(working: working, saved: saved) == .saved)
    }

    @Test func loadDecisionOrder() {
        let a = UUID(), b = UUID()

        #expect(Rules.loadDecision(target: a, loaded: a, status: .edited, isCapturing: true) == .refuseWhileCapturing)
        #expect(Rules.loadDecision(target: b, loaded: a, status: .saved, isCapturing: true) == .refuseWhileCapturing)
        #expect(Rules.loadDecision(target: a, loaded: a, status: .edited, isCapturing: false) == .alreadyLoaded)
        #expect(Rules.loadDecision(target: b, loaded: a, status: .edited, isCapturing: false) == .askToSaveFirst)
        #expect(Rules.loadDecision(target: b, loaded: nil, status: .notSaved, isCapturing: false) == .askToSaveFirst)
        #expect(Rules.loadDecision(target: b, loaded: a, status: .saved, isCapturing: false) == .load)
    }

    @Test func saveNameCheck() {
        let arena = ConfigurationSummary(id: UUID(), name: "Arena", channelCount: 0, savedAt: .now)
        let theatre = ConfigurationSummary(id: UUID(), name: "Theatre", channelCount: 0, savedAt: .now)
        let all = [arena, theatre]

        #expect(Rules.saveNameCheck(name: "Theatre", loaded: theatre.id, in: all) == nil)
        #expect(Rules.saveNameCheck(name: " arena ", loaded: theatre.id, in: all) == .nameTaken("Arena"))
        #expect(Rules.saveNameCheck(name: "  ", loaded: theatre.id, in: all) == .emptyName)
        #expect(Rules.saveNameCheck(name: "Stadium", loaded: theatre.id, in: all) == nil)
    }

    @Test func titleSuffix() {
        #expect(Rules.titleSuffix(.saved) == "")
        #expect(Rules.titleSuffix(.edited) == " — Edited")
        #expect(Rules.titleSuffix(.notSaved) == " — Not Saved")
    }

    @Test func errorMessages() {
        #expect(ConfigurationError.emptyName.message == "A configuration needs a name.")
        #expect(ConfigurationError.nameTaken("Arena").message == "Another configuration is already called “Arena”.")
    }

    @Test func loadedIDDropsWhenItsFileIsGone() {
        let arena = ConfigurationSummary(id: UUID(), name: "Arena", channelCount: 0, savedAt: .now)

        #expect(Rules.stillLoaded(arena.id, in: [arena]) == arena.id)
        #expect(Rules.stillLoaded(UUID(), in: [arena]) == nil)
        #expect(Rules.stillLoaded(nil, in: [arena]) == nil)
    }
}
