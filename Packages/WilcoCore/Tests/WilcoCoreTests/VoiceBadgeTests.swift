import Foundation
import Testing
@testable import WilcoCore

@Suite("Voice badge")
struct VoiceBadgeTests {
    private let channel = UUID()
    private let other = UUID()

    private func line(_ voice: String?, exchange: Int? = 1, channel: UUID? = nil) -> TranscriptSegment {
        TranscriptSegment(
            channelID: channel ?? self.channel, text: "x", timestamp: Date(), sessionOffset: 0,
            isFinal: true, voice: voice, exchange: exchange
        )
    }

    @Test func noColumnWhenTheFeatureIsOff() {
        #expect(VoiceBadge.label(voice: "A", exchange: 1, detectsVoiceChanges: false, modelInstalled: true) == nil)
    }

    @Test func noColumnWhenTheModelIsMissing() {
        #expect(VoiceBadge.label(voice: "A", exchange: 1, detectsVoiceChanges: true, modelInstalled: false) == nil)
    }

    @Test func showsTheLetter() {
        #expect(VoiceBadge.label(voice: "B", exchange: 2, detectsVoiceChanges: true, modelInstalled: true) == "B")
    }

    @Test func dotForAnnotatedLineWithoutVoice() {
        #expect(VoiceBadge.label(voice: nil, exchange: 3, detectsVoiceChanges: true, modelInstalled: true) == "·")
    }

    @Test func blankForLineNeverAnnotated() {
        #expect(VoiceBadge.label(voice: nil, exchange: nil, detectsVoiceChanges: true, modelInstalled: true) == "")
    }

    @Test func turnStartsWhereTheLetterChangesOnTheSameChannel() {
        let a1 = line("A"), b = line("B"), a2 = line("A")
        #expect(VoiceBadge.turnStarts(in: [a1, b, a2]) == [b.id, a2.id])
    }

    @Test func sameLetterInANewExchangeIsANewTurn() {
        let first = line("A", exchange: 1), second = line("A", exchange: 2), third = line("A", exchange: 2)
        #expect(VoiceBadge.turnStarts(in: [first, second, third]) == [second.id])
    }

    @Test func channelsAreComparedSeparately() {
        let a = line("A"), b = line("B", channel: other), a2 = line("A")
        #expect(VoiceBadge.turnStarts(in: [a, b, a2]).isEmpty)
    }

    @Test func firstLineOfAChannelIsNotATurn() {
        #expect(VoiceBadge.turnStarts(in: [line("A")]).isEmpty)
    }

    @Test func linesWithoutVoiceInfoNeverStartTurns() {
        let plain1 = line(nil, exchange: nil), plain2 = line(nil, exchange: nil)
        #expect(VoiceBadge.turnStarts(in: [plain1, plain2]).isEmpty)
    }
}
