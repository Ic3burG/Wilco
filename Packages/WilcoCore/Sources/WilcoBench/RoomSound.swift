import Foundation

/// Speech as a mic in a room hears it. Clean `say` audio has deep dips
/// between syllables; a room fills them, which is what makes continuous
/// talking hard to tell from steady background.
public enum RoomSound {
    /// Four early echoes: delay in seconds, and gain.
    public static let echoes: [(delay: Double, gain: Float)] = [
        (0.03, 0.5), (0.07, 0.35), (0.13, 0.25), (0.21, 0.15),
    ]
    public static let hissLevel: Float = 0.002

    /// `samples` with the echoes added. Longer than the input by the last
    /// echo's delay.
    public static func echoed(_ samples: [Float], sampleRate: Double) -> [Float] {
        let shifts = echoes.map { Int(($0.delay * sampleRate).rounded()) }
        var out = samples + [Float](repeating: 0, count: shifts.max() ?? 0)
        for (echo, shift) in zip(echoes, shifts) {
            for index in samples.indices { out[index + shift] += samples[index] * echo.gain }
        }
        return out
    }

    /// Uniform noise within ±`level` for one frame. It depends only on the
    /// seed and the frame, so a track sounds the same however it's cut into
    /// chunks, and a failing run can be played again.
    public static func hiss(frame: Int, seed: UInt64, level: Float = hissLevel) -> Float {
        var z = (seed &+ 1) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(truncatingIfNeeded: frame) &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Float(z >> 40) / Float(1 << 24)  // [0, 1)
        return (unit * 2 - 1) * level
    }
}
