import Foundation

struct SayClipError: Error { var message: String }

/// The installed voice whose name starts with `base`, e.g. "Daniel" finds
/// "Daniel (English (UK))" on Macs that name voices that way. Falls back to `base`.
func sayVoice(_ base: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "?"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    // Each line is the voice name, padding, then the locale ("en_GB").
    let names = output.split(separator: "\n").compactMap { line -> String? in
        guard let locale = line.range(of: #"\s+[a-z]{2,3}_[A-Za-z0-9]+\s+#"#, options: .regularExpression) else { return nil }
        return String(line[..<locale.lowerBound])
    }
    return names.first { $0 == base } ?? names.first { $0.hasPrefix(base + " (") } ?? base
}

/// `text` spoken by a system voice, as 16 kHz mono samples.
func sayClip(_ text: String, voice: String = "Samantha") throws -> [Float] {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SayClipError(message: "say failed (\(process.terminationStatus))") }
    let data = try Data(contentsOf: file)
    // Float32 samples follow the "data" chunk header (tag + 4-byte size).
    guard let range = data.range(of: Data("data".utf8)), range.upperBound + 4 <= data.count else {
        throw SayClipError(message: "no audio in say output")
    }
    let start = range.upperBound + 4
    let count = (data.count - start) / 4
    return data.withUnsafeBytes { raw in
        (0..<count).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: start + $0 * 4, as: UInt32.self).littleEndian) }
    }
}
