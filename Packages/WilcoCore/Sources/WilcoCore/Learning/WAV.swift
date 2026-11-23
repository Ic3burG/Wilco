import Foundation

/// Mono 16-bit PCM WAV, the format clips are kept in.
public enum WAV {
    public struct DecodeError: Error, Equatable, Sendable {
        public var reason: String
    }

    /// Encodes samples (clamped to -1...1) as a mono 16-bit PCM file.
    public static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))                       // PCM
        data.append(le16(1))                       // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))  // byte rate
        data.append(le16(2))                       // block align
        data.append(le16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(UInt32(dataSize)))
        for sample in samples {
            let clamped = max(-1, min(1, sample.isNaN ? 0 : sample))
            data.append(le16(UInt16(bitPattern: Int16((clamped * 32767).rounded()))))
        }
        return data
    }

    /// Decodes a mono 16-bit PCM file; anything else throws.
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WAVE" else {
            throw DecodeError(reason: "not a WAV file")
        }
        var sampleRate: Int?
        var position = 12
        while position + 8 <= bytes.count {
            let id = tag(bytes, position)
            let size = Int(u32(bytes, position + 4))
            let body = position + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { throw DecodeError(reason: "short fmt chunk") }
                guard u16(bytes, body) == 1, u16(bytes, body + 2) == 1, u16(bytes, body + 14) == 16 else {
                    throw DecodeError(reason: "not mono 16-bit PCM")
                }
                sampleRate = Int(u32(bytes, body + 4))
            } else if id == "data" {
                guard let sampleRate else { throw DecodeError(reason: "data before fmt") }
                let end = min(body + size, bytes.count)
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 2 <= end {
                    samples.append(Float(Int16(bitPattern: u16(bytes, i))) / 32767)
                    i += 2
                }
                return (samples, sampleRate)
            }
            position = body + size + (size & 1)
        }
        throw DecodeError(reason: "no data chunk")
    }

    private static func tag(_ b: [UInt8], _ at: Int) -> String {
        guard at + 4 <= b.count else { return "" }
        return String(decoding: b[at ..< at + 4], as: UTF8.self)
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
