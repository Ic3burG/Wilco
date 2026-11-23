import Foundation
import Testing
import WilcoCore
@testable import WilcoTranscription

@Suite("Clip voters")
struct ClipVoterTests {
    /// Each voter installed on this Mac hears a spoken call. Apple long-form
    /// writes "cue forty two" as "Q 42", so the check is on another word.
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
            #expect(words.contains("lighting") && words.contains("forty"), "\(voter.id) heard \"\(text)\"")
        }
        print("voters installed: \(voters.map(\.id))")
    }
}
