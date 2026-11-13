import Foundation
import WilcoBench

// Multichannel transcription benchmark. Run from Packages/WilcoCore:
//
//   swift run -c release wilco-bench --list
//   swift run -c release wilco-bench --engines whisper-base,apple-longform --channels 1,8,16,32
//
// Build in release: debug builds are several times slower and would make
// every engine look worse than it is.

let usage = """
    Usage: wilco-bench [options]

      --list                 Show the engines and whether each can run here.
      --engines a,b,…        Engines to run (default: every available one).
      --channels 1,8,…       Channel counts to try (default: 1,8,16,32).
      --duration SECONDS     Length of each run (default: 60).
      --duty FRACTION        Share of time each channel talks, 0–1 (default: 0.3).
      --seed N               Seed for who talks when (default: 1).
      --corpus FOLDER        Use recordings (name.wav + name.txt) instead of `say`.
      --voices N             Number of `say` voices (default: 4).
      --out FOLDER           Where to write the JSON and Markdown report
                             (default: ./bench-results).
      --stop-when-behind     Skip an engine's larger channel counts once it
                             can't keep up.
    """

struct Options {
    var list = false
    var engines: [String]?
    var channels = [1, 8, 16, 32]
    var duration = 60.0
    var duty = 0.3
    var seed: UInt64 = 1
    var corpus: URL?
    var voices = 4
    var out = URL(fileURLWithPath: "bench-results", isDirectory: true)
    var stopWhenBehind = false
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) needs a value") }
        return next
    }
    func number<T: LosslessStringConvertible>(_ flag: String, where valid: (T) -> Bool = { _ in true }) -> T {
        guard let parsed = T(value(flag)), valid(parsed) else { fail("bad value for \(flag)") }
        return parsed
    }
    func list<T>(_ flag: String, _ convert: (String) -> T?) -> [T] {
        let items = value(flag).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let converted = items.compactMap(convert)
        guard converted.count == items.count, !converted.isEmpty else { fail("bad value for \(flag)") }
        return converted
    }
    while let argument = iterator.next() {
        switch argument {
        case "--list": options.list = true
        case "--engines": options.engines = list(argument) { $0 }
        case "--channels": options.channels = list(argument) { Int($0).flatMap { $0 > 0 ? $0 : nil } }
        case "--duration": options.duration = number(argument) { $0 > 0 }
        case "--duty": options.duty = number(argument) { $0 > 0 && $0 < 1 }
        case "--seed": options.seed = number(argument)
        case "--corpus": options.corpus = URL(fileURLWithPath: value(argument), isDirectory: true)
        case "--voices": options.voices = number(argument) { $0 > 0 }
        case "--out": options.out = URL(fileURLWithPath: value(argument), isDirectory: true)
        case "--stop-when-behind": options.stopWhenBehind = true
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wilco-bench: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func machineDescription() -> String {
    let chip = sysctl("machdep.cpu.brand_string") ?? "Unknown Mac"
    let cores = ProcessInfo.processInfo.processorCount
    let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    return "\(chip), \(cores) cores, \(memory) GB"
}

let options = parse(Array(CommandLine.arguments.dropFirst()))

// Which engines can run here.
var available: [BenchEngine] = []
for engine in BenchEngine.builtIn {
    let reason = await engine.unavailableReason()
    if options.list {
        print("\(engine.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(reason.map { "unavailable: \($0)" } ?? "ready")  — \(engine.summary)")
    }
    if reason == nil { available.append(engine) }
}
if options.list { exit(0) }

let engines: [BenchEngine]
if let requested = options.engines {
    engines = requested.map { id in
        guard let engine = BenchEngine.named(id) else { fail("no engine called \(id); see --list") }
        guard available.contains(where: { $0.id == id }) else { fail("\(id) can't run on this Mac; see --list") }
        return engine
    }
} else {
    engines = available
}
guard !engines.isEmpty else { fail("no engines can run on this Mac; see --list") }

let sampleRate = 48_000.0
let clips: [BenchClip]
let corpusName: String
do {
    if let folder = options.corpus {
        clips = try ClipLibrary.load(folder: folder, sampleRate: sampleRate)
        corpusName = "\(clips.count) recordings from \(folder.lastPathComponent)"
    } else {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "WilcoBench/say", directoryHint: .isDirectory)
        log("Rendering speech with `say` (cached after the first run)…")
        let synthesized = try ClipLibrary.synthesized(sampleRate: sampleRate, cacheDirectory: cache, voiceLimit: options.voices)
        clips = synthesized.clips
        corpusName = "say (\(synthesized.voices.joined(separator: ", ")); \(clips.count) clips"
    }
} catch {
    fail(error.localizedDescription)
}

let runner = BenchRunner(clips: clips, sampleRate: sampleRate)
let durations = clips.map { $0.duration(sampleRate: sampleRate) }
let started = Date()
let stamp = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: started)
}()
var report = BenchReport(
    date: started, machine: machineDescription(),
    osVersion: ProcessInfo.processInfo.operatingSystemVersionString, corpus: corpusName, results: []
)

@MainActor func save() {
    do {
        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: options.out.appending(path: "bench-\(stamp).json"))
        try Data(report.markdown().utf8).write(to: options.out.appending(path: "bench-\(stamp).md"))
    } catch {
        log("Could not save the report: \(error.localizedDescription)")
    }
}

log("Measuring idle CPU…")
report.idleSystemCPU = await BenchRunner.idleSystemCPU()
log(String(format: "Mac idle: %.0f%% of all cores busy", (report.idleSystemCPU ?? 0) * 100))
log("\(report.machine) · \(engines.count) engine(s) × channels \(options.channels) · \(Int(options.duration)) s runs, \(Int(options.duty * 100))% talk time")
print(BenchReport.tableHeader)
for engine in engines {
    for channels in options.channels {
        let scenario = Scenario.generate(
            channelCount: channels, clipDurations: durations,
            duration: options.duration, dutyCycle: options.duty, seed: options.seed
        )
        log("→ \(engine.id) × \(channels) channels (\(scenario.utteranceCount) calls)…")
        let result = await runner.run(engine: engine, scenario: scenario)
        report.results.append(result)
        print(BenchReport.tableRow(result))
        save()
        if options.stopWhenBehind, !result.keepsUp {
            log("  \(engine.id) fell behind at \(channels) channels; skipping larger counts.")
            break
        }
        // Let the previous run's work and memory settle.
        try? await Task.sleep(for: .seconds(3))
    }
}
log("Report: \(options.out.appending(path: "bench-\(stamp).md").path)")
