@preconcurrency import AVFoundation

/// Streams mono float audio from the capture rate to an engine's format,
/// keeping filter state between calls so chunk edges stay seamless.
final class SampleRateConverter {
    let output: AVAudioFormat
    private var input: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) {
        self.output = output
    }

    /// 16 kHz mono float, what Whisper expects.
    static func whisper() -> SampleRateConverter {
        SampleRateConverter(output: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    }

    /// Converts one chunk. Returns every buffer the converter can produce
    /// from it: it stops when an output buffer fills, so it is drained in a loop.
    func convert(_ samples: [Float], sampleRate: Double) throws -> [AVAudioPCMBuffer] {
        // Rate is 0 while a channel's device is not connected.
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        if input?.sampleRate != sampleRate {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            input = format
            converter = AVAudioConverter(from: format, to: output)
        }
        guard let input, let converter else { throw ConversionError() }

        let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))!
        source.frameLength = source.frameCapacity
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }

        let capacity = AVAudioFrameCount(Double(samples.count) * output.sampleRate / sampleRate) + 64
        let supplied = Supplied()
        var buffers: [AVAudioPCMBuffer] = []
        var status: AVAudioConverterOutputStatus
        repeat {
            let destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
            var error: NSError?
            status = converter.convert(to: destination, error: &error) { _, inputStatus in
                if supplied.done {
                    // Not end of stream: the converter keeps its state for the next call.
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied.done = true
                inputStatus.pointee = .haveData
                return source
            }
            if let error { throw error }
            if destination.frameLength > 0 { buffers.append(destination) }
        } while status == .haveData
        return buffers
    }

    func convertToSamples(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        try convert(samples, sampleRate: sampleRate).flatMap { buffer in
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
    }

    private final class Supplied: @unchecked Sendable { var done = false }
    struct ConversionError: Error {}
}
