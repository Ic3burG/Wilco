import Foundation
import Testing
import WilcoCore
import WilcoTranscription
@testable import WilcoBench

@Suite("Long talks")
struct LongTalkTests {
    @Test func echoesLandAtTheirDelays() {
        var impulse = [Float](repeating: 0, count: 100)
        impulse[0] = 1
        let out = RoomSound.echoed(impulse, sampleRate: 1_000)
        #expect(out.count == 100 + 210)
        #expect(out[0] == 1 && out[30] == 0.5 && out[70] == 0.35 && out[130] == 0.25 && out[210] == 0.15)
        #expect(out[31] == 0)
    }

    @Test func hissIsTheSameForTheSameFrame() {
        let a = (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) }
        #expect(a == (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 7) })
        #expect(a != (0..<1_000).map { RoomSound.hiss(frame: $0, seed: 8) })
        let loudest = a.map(abs).max() ?? 0
        #expect(loudest <= 0.002)
        #expect(Set(a).count > 900)
    }

    @Test func passagesAreLongAndPlainWords() {
        #expect(ClipLibrary.passages.count >= 6)
        for passage in ClipLibrary.passages {
            let words = TranscriptNormalizer.words(passage)
            #expect((30...75).contains(words.count), "\(words.count) words")  // about 10–25 s
            let hasDigits = passage.contains(where: \.isNumber)
            #expect(!hasDigits)
        }
    }
}
