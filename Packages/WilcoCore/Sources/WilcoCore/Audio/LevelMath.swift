import Accelerate

public enum LevelMath {
    /// Meters bottom out here. Comms rarely matter below it.
    public static let floorDecibels: Float = -60

    /// Largest sample magnitude among `count` samples spaced `stride` apart.
    /// Real-time safe.
    public static func peak(_ samples: UnsafePointer<Float>, count: Int, stride: Int) -> Float {
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_maxmgv(samples, vDSP_Stride(stride), &result, vDSP_Length(count))
        return result
    }

    /// Maps a linear amplitude to 0...1, linear in decibels between
    /// ``floorDecibels`` and 0 dBFS. Meters stay honest: no smoothing curve
    /// that could show a level the signal never reached.
    public static func meterPosition(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}
