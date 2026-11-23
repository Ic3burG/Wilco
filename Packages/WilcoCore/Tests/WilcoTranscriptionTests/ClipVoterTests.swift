import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Clip voters")
struct ClipVoterTests {
    /// Each voter installed on this Mac hears a spoken call.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil))
    func votersTranscribeASayClip() async throws {
        let ultra = ParakeetModelStore(
            directory: DataLocations.parakeetUltraModels, version: .ultra,
            vocabularyDirectory: DataLocations.parakeetModels
        )
        let voters = await ClipVoters.installed(ultra: ultra, whisper: WhisperModelStore())
        let samples = try sayClip("Standby lighting cue forty two")
        for voter in voters {
            let text = try await voter.transcribe(samples, vocabulary: [], localeIdentifier: "en-US")
            print("voter \(voter.id) (\(voter.version)): \(text)")
            let words = TranscriptNormalizer.words(text)
            #expect(words.contains("cue"), "\(voter.id) heard \"\(text)\"")
        }
        print("voters installed: \(voters.map(\.id))")
    }

    /// An empty clip gives no text rather than waiting for results forever.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILCO_ASR_TESTS"] != nil), .timeLimit(.minutes(1)))
    func appleVoterReturnsForAnEmptyClip() async throws {
        guard #available(macOS 26, *) else { return }
        let voter = await AppleLongFormVoter.checking(localeIdentifier: "en-US")
        guard voter.isInstalled() else { return }
        let text = try await voter.transcribe([], vocabulary: ["cue"], localeIdentifier: "en-US")
        #expect(text.isEmpty)
    }
}
