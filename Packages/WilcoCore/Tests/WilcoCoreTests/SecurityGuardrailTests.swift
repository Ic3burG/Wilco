import Foundation
import Testing

/// Guardrails for `docs/SECURITY-MODEL.md`. They read the project's own
/// source and settings, so a change that widens what Wilco trusts, listens
/// to, sends, runs or logs fails here until someone decides it should.
///
/// A failure is not "add the file to the list". It means: read the section
/// of the security model named in the message, build what it asks for (with
/// tests), then widen the list in the same commit.
@Suite("Security guardrails")
struct SecurityGuardrailTests {
    // MARK: Source rules

    struct Rule: Sendable, CustomTestStringConvertible {
        var name: String
        /// Regular expression matched against each line that isn't a comment.
        var pattern: String
        /// File names (not paths) allowed to match.
        var allowed: Set<String>
        var why: String
        var testDescription: String { name }
    }

    static let rules: [Rule] = [
        Rule(name: "Outbound HTTP", pattern: #"URLSession|NSURLConnection|CFHTTP"#,
             allowed: ["WebhookSender.swift"],
             why: "All HTTP goes through WebhookSender: no cookies, cache or credentials, and no redirects (model §4.3)."),
        Rule(name: "Outbound sockets", pattern: #"NWConnection|CFStream|\bsocket\("#,
             allowed: ["OSCSender.swift"],
             why: "A new way to send data needs its destination covered by OutboundRules on import (model §4.2, §4.3)."),
        Rule(name: "Listening on the network", pattern: #"NWListener|NWBrowser|NetService|CFSocket|\bbind\(|\blisten\("#,
             allowed: [],
             why: "Nothing listens yet. A listener needs authentication, size limits and to be off by default first (model §4.4, spec §12.1)."),
        Rule(name: "Wildcard CORS", pattern: #"Access-Control-Allow-Origin"#,
             allowed: [],
             why: "With a CORS header any web page on the Mac could read live comms (model §4.4)."),
        Rule(name: "Running other programs", pattern: #"\bProcess\(\)|NSTask|posix_spawn|(?<![.\w])system\(|\bpopen\(|NSAppleScript|OSAScript|\bdlopen\(|NSUserScriptTask"#,
             allowed: [],
             why: "The app never runs another program or script; only the benchmark tool does (model §4.6)."),
        Rule(name: "Decoding files", pattern: #"JSONDecoder\(|PropertyListDecoder\(|NSKeyedUnarchiver|JSONSerialization"#,
             allowed: ["WilcoJSON.swift", "ClipDiarizers.swift"],
             why: "Files are decoded in one place so every format is repaired on read (FileRepair) and fuzzed (HostileInputTests) (model §4.1)."),
        Rule(name: "Regular expressions", pattern: #"NSRegularExpression\(|\bRegex\(|\bRegex<"#,
             allowed: ["KeywordMatcher.swift", "MarkerDetector.swift", "ShowReport.swift"],
             why: "A pattern from a file must go through KeywordMatcher's safety check and time limit (model §4.5)."),
        Rule(name: "Code that crashes on purpose", pattern: #"try!|\bas!|fatalError\(|preconditionFailure\(|unsafelyUnwrapped"#,
             allowed: ["MarkerDetector.swift", "SidebarOutline.swift"],
             why: "A crash mid-show loses comms. Handle the failure instead (model §4.1)."),
        Rule(name: "Dictionaries that trap on duplicate keys", pattern: #"uniqueKeysWithValues"#,
             allowed: ["MultiDeviceCapture.swift", "MatrixLayout.swift", "ShowDocument+Groups.swift"],
             why: "Traps when keys repeat. Use `uniquingKeysWith:` unless the keys were made unique by FileRepair (model §4.1)."),
        Rule(name: "Logging", pattern: #"\bLogger\(|os_log\(|NSLog\(|\bprint\(|debugPrint\(|\bdump\("#,
             allowed: [],
             why: "What is heard on comms must never reach the system log, where other tools and reports can read it (model §4.7)."),
        Rule(name: "Speech recognition that can leave the Mac", pattern: #"SFSpeechRecognizer|SFSpeechRecognitionRequest|SFSpeechAudioBufferRecognitionRequest"#,
             allowed: [],
             why: "That API can send audio to a server. Use the on-device SpeechAnalyzer modules (model §4.7)."),
        Rule(name: "Reading the environment", pattern: #"processInfo\.environment|\bgetenv\("#,
             allowed: [],
             why: "Behaviour must not depend on inherited environment variables (model §4.6)."),
        Rule(name: "Markup from text", pattern: #"innerHTML|WKWebView|WebView\(|NSAttributedString\(html|AttributedString\(markdown|LocalizedStringKey\("#,
             allowed: ["ShowReportHTML.swift"],
             why: "Text from shows and speech is shown as text, never parsed as HTML or Markdown (model §4.8)."),
        Rule(name: "Raw memory", pattern: #"Unsafe(Mutable)?(Raw)?(Buffer)?Pointer|withUnsafe|assumingMemoryBound|bindMemory|unsafeBitCast|Unmanaged<"#,
             allowed: [
                "AudioRingBuffer.swift", "PeakSlots.swift", "ChannelMeter.swift", "AudioHistory.swift", "LevelMath.swift",
                "OSCMessage.swift", "HAL.swift", "AudioCaptureEngine.swift", "MIDIOutput.swift", "SampleRateConverter.swift",
                "SoundClassifierQueue.swift", "ClipDiarizers.swift", "OutboundRules.swift",
             ],
             why: "Raw memory needs its bounds proved before use, and never from a value read from a file (model §4.9)."),
        Rule(name: "Opting out of concurrency checks", pattern: #"@unchecked Sendable|nonisolated\(unsafe\)"#,
             allowed: [
                "AudioCaptureEngine.swift", "AudioDevices.swift", "MultiDeviceCapture.swift", "MIDIOutput.swift",
                "AudioRingBuffer.swift", "PeakSlots.swift", "KeywordMatcher.swift", "SampleRateConverter.swift",
                "SoundClassifierQueue.swift", "VoiceprintExtractor.swift",
             ],
             why: "Each one is a promise the compiler can't check. Say in a comment why it holds (model §4.9)."),
        Rule(name: "Deleting files", pattern: #"removeItem\(|trashItem\("#,
             allowed: [
                "ClipFiles.swift", "ConfigurationStore.swift", "MarkerPresetStore.swift", "ClipDiarizers.swift",
                "ClipKeeper.swift", "ParakeetModelStore.swift", "VoiceprintExtractor.swift", "WhisperChannelTranscriber.swift",
             ],
             why: "A delete path must be built from a UUID or a fixed name inside Wilco's own folder, never from text in a file (model §4.1)."),
    ]

    /// The app and the libraries it links. The benchmark tool is a
    /// developer command-line program and isn't shipped.
    static let sourceFolders = [
        "Wilco", "Packages/WilcoCore/Sources/WilcoCore", "Packages/WilcoCore/Sources/WilcoAudio",
        "Packages/WilcoCore/Sources/WilcoTranscription", "Packages/WilcoCore/Sources/WilcoControl",
    ]

    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // file, WilcoCoreTests, Tests, WilcoCore, Packages
        return url
    }()

    static func sourceFiles() -> [URL] {
        sourceFolders.flatMap { folder -> [URL] in
            let files = FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil)
            return (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
    }

    @Test func theSourceTreeIsWhereTheTestExpects() {
        #expect(Self.sourceFiles().count > 100)
    }

    @Test(arguments: rules)
    func sourceRule(_ rule: Rule) throws {
        let expression = try NSRegularExpression(pattern: rule.pattern)
        var used = Set<String>()
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      expression.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                else { continue }
                used.insert(file.lastPathComponent)
                if !rule.allowed.contains(file.lastPathComponent) {
                    Issue.record("\(rule.name): \(file.lastPathComponent):\(number + 1) is outside the allowed files. \(rule.why) See docs/SECURITY-MODEL.md.")
                }
            }
        }
        // Keeps the lists honest: a file that no longer needs its exception loses it.
        let stale = rule.allowed.subtracting(used)
        #expect(stale.isEmpty, "\(rule.name): \(stale.sorted()) no longer match; remove them from the allowed list.")
    }

    // MARK: Settings

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appending(path: path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Each entitlement is something the system lets Wilco do that it
    /// otherwise wouldn't. The dangerous ones switch off code-signing checks.
    @Test func entitlementsAreOnlyTheMicrophone() throws {
        #expect(Set(try plist("Config/Wilco.entitlements").keys) == ["com.apple.security.device.audio-input"])
    }

    @Test func infoPlistOpensNoNewDoors() throws {
        let info = try plist("Config/Info.plist")
        #expect(info["NSAppTransportSecurity"] == nil, "No exceptions to App Transport Security.")
        #expect(info["CFBundleURLTypes"] == nil, "A URL scheme lets any web page or app send Wilco input (model §4.4).")
        #expect(info["CFBundleDocumentTypes"] == nil, "Opening files by double-click is a new way in; it needs the import rules (model §4.2).")
        #expect(info["NSServices"] == nil)
        #expect(info["NSBonjourServices"] as? [String] == ["_wilco._tcp"])
        #expect((info["SUFeedURL"] as? String)?.hasPrefix("https://") == true, "Updates are fetched over HTTPS only.")
    }

    @Test func hardenedRuntimeStaysOn() throws {
        let project = try String(contentsOf: Self.root.appending(path: "Wilco.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(project.contains("ENABLE_HARDENED_RUNTIME = YES"))
        #expect(!project.contains("ENABLE_HARDENED_RUNTIME = NO"))
    }

    // MARK: Supply chain

    /// A new dependency is new code with the app's full access. Adding one
    /// is a decision, recorded here (model §4.10).
    @Test func dependenciesAreTheKnownOnes() throws {
        let manifest = try String(contentsOf: Self.root.appending(path: "Packages/WilcoCore/Package.swift"), encoding: .utf8)
        let project = try String(contentsOf: Self.root.appending(path: "Wilco.xcodeproj/project.pbxproj"), encoding: .utf8)
        let urls = try NSRegularExpression(pattern: #"https://[A-Za-z0-9./_-]+"#)
        func remotes(_ text: String, marker: String) -> Set<String> {
            Set(text.split(separator: "\n").filter { $0.contains(marker) }.compactMap { line -> String? in
                let line = String(line)
                return urls.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
                    .flatMap { Range($0.range, in: line) }.map { String(line[$0]) }
            })
        }
        #expect(remotes(manifest, marker: ".package(url:") == [
            "https://github.com/argmaxinc/WhisperKit", "https://github.com/FluidInference/FluidAudio",
        ])
        #expect(remotes(project, marker: "repositoryURL") == ["https://github.com/sparkle-project/Sparkle"])
    }

    @Test func workflowsPinActionsAndStayReadOnly() throws {
        let folder = Self.root.appending(path: ".github/workflows")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["yml", "yaml"].contains($0.pathExtension) }
        #expect(!files.isEmpty)
        let pinned = try NSRegularExpression(pattern: #"uses:\s*[\w./-]+@[0-9a-f]{40}(\s|$)"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").map(String.init) where line.contains("uses:") {
                #expect(pinned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                        "\(file.lastPathComponent): pin to a commit SHA, not a tag: \(line.trimmingCharacters(in: .whitespaces))")
            }
            #expect(text.contains("permissions:\n  contents: read"), "\(file.lastPathComponent): the workflow token stays read-only.")
            #expect(!text.contains("pull_request_target"), "pull_request_target runs with secrets on code from forks.")
        }
    }

    // MARK: What gets published

    /// `git ls-files`, or nil where there is no git (the test then skips).
    private static func trackedFiles() -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// The repository is public. The reference folder holds someone else's
    /// app and the user's real show; private keys, recordings and archives
    /// never belong in git either.
    @Test func nothingPrivateIsTracked() throws {
        let files = try #require(Self.trackedFiles(), "git is needed for this check")
        #expect(files.filter { $0.hasPrefix("reference/") } == ["reference/README.md"])
        let banned: Set<String> = [
            "p12", "pem", "key", "cer", "mobileprovision", "provisionprofile", "env", "ips", "crash", "app", "dmg", "pkg",
            "zip", "wav", "m4a", "caf", "aiff", "mp3", "sqlite", "mlmodelc", "mlpackage", "clips", "diagnostics",
        ]
        let found = files.filter { banned.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        #expect(found.isEmpty, "These kinds of file don't belong in a public repository: \(found)")
        let ignore = try String(contentsOf: Self.root.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore.contains("/reference/*"))
    }

    /// Words that must not appear anywhere in the project (CLAUDE.md, "Don't
    /// name or version the reference app"). The list itself is private, so it
    /// lives in the untracked reference folder and this runs only on a Mac
    /// that has it. A worktree has no reference folder of its own, so the
    /// main checkout's is used.
    static let forbiddenWords: [String] = {
        var folders = [root]
        let common = Process()
        common.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        common.arguments = ["-C", root.path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        let pipe = Pipe()
        common.standardOutput = pipe
        common.standardError = Pipe()
        if (try? common.run()) != nil {
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            common.waitUntilExit()
            if !path.isEmpty { folders.append(URL(fileURLWithPath: path).deletingLastPathComponent()) }
        }
        for folder in folders {
            if let text = try? String(contentsOf: folder.appending(path: "reference/forbidden-words.txt"), encoding: .utf8) {
                return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            }
        }
        return []
    }()

    @Test(.enabled(if: !forbiddenWords.isEmpty))
    func theReferenceAppIsNeverNamed() throws {
        let files = try #require(Self.trackedFiles(), "git is needed for this check")
        for path in files {
            if Self.forbiddenWords.contains(where: path.lowercased().contains) {
                Issue.record("A tracked file's name contains a forbidden word (not shown): \(path.count) characters long, in \(URL(fileURLWithPath: path).deletingLastPathComponent().path)")
            }
            guard let text = try? String(contentsOf: Self.root.appending(path: path), encoding: .utf8) else { continue }
            let lowered = text.lowercased()
            if Self.forbiddenWords.contains(where: lowered.contains) {
                Issue.record("\(path) contains a word from reference/forbidden-words.txt. Say \"the reference app\" instead.")
            }
        }
    }
}
