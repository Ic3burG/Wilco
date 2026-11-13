# Wilco — reconstruction spec

Derived from the shipped **0.2.0** app (arm64,
SHA-256 `6e92bf9e…0824f9`) to guide a clean rebuild. Nothing here is copied
source: it is behaviour, data shapes and user-facing text recovered from the
binary's Swift metadata, symbols, string literals and targeted decompilation,
plus the user's own save/transcript files.

Names, paths and identifiers below are given as Wilco uses them.

Evidence key used below:

- **[meta]** — Swift reflection metadata (`__swift5_fieldmd`): exact stored
  property names/types and enum cases. See `reference/swift-fields.txt`.
- **[sym]** — unstripped symbol names (types, methods). `reference/swift-members.txt`.
- **[str]** — string literals (`reference/strings.txt`, line numbers given) or
  inline small strings (`reference/swift-small-strings.txt`).
- **[file]** — observed in the user's real data files.
- **[dis]** — disassembly / Ghidra decompilation.
- **[inferred]** — reasoned from the above, not directly observed. Treat as a
  design choice we are free to change.

---

## 1. What Wilco is

A macOS menu-less, single-window app for live-event **comms transcription**.
It captures many channels of a multichannel audio interface (e.g. Dante
Virtual Soundcard — the user's show uses device UID `AUDINATE-DVS-UID`),
transcribes each channel on-device, shows them as a combined log or a
per-channel matrix, and fires **automation** (OSC / MIDI / webhook /
notification / cue marker / MOS) when phrases are heard. Machines on the same
LAN can share transcripts; a local MCP server exposes read-only status.

Minimum OS in 0.2.0: **macOS 15.0** (`LSMinimumSystemVersion`). Apple's new
`SpeechAnalyzer` engines need **macOS 26**; Whisper is the fallback below 26.
[str 18265–18270]

## 2. Third-party components

| Component | Purpose | Rebuild |
|---|---|---|
| **WhisperKit** + ArgmaxCore (Argmax, MIT) | On-device Whisper | SPM package `argmaxinc/WhisperKit` |
| **Sparkle 2.10** | Updates | SPM `sparkle-project/Sparkle`; real feed + EdDSA key needed (0.2.0 shipped placeholders `updates.example.com`, `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`) |
| **TurboActivate** | Licensing | **Drop.** 0.2.0 never bundled `libTurboActivate.dylib`; the app itself reports *"Licensing is not active in this build… Capture is not gated until then."* [str 18300–18330] |

Apple frameworks used: SwiftUI/AppKit, CoreAudio (HAL, direct IOProc),
AVFoundation, Speech (`SpeechAnalyzer`/`SpeechTranscriber`/`DictationTranscriber`),
CoreMIDI, Network (`NWListener`/`NWBrowser`/`NWConnection`), Observation,
NaturalLanguage, CryptoKit, OSLog.

## 3. Files on disk

All under `~/Library/Application Support/Wilco/` [file]:

| Path | Format |
|---|---|
| `Current.wilco` | The open show: JSON-encoded `ShowDocument` (§4). Autosaved (`ShowStore.scheduleSave` debounced, `saveNow`). If unreadable on launch it is renamed `Current-unreadable-<…>` and the user is told *"Could not open the previous show file. It has been kept at …"* [str, sym] |
| `Configurations/‹UUID›.wilco` | **New in the rebuild, not in 0.2.0.** Saved show setups, one plain `ShowDocument` each (same format as `Current.wilco`). `Current.wilco` stays the autosaved working copy; a configuration changes only on Save. The loaded one's UUID is in `UserDefaults` `configurations.loaded`. See `docs/superpowers/specs/2026-11-12-configurations-design.md`. |
| `Transcripts/Session yyyy-MM-dd HHmm-ss.jsonl` | One `TranscriptSegment` JSON object per line, appended as each line is finalised (`TranscriptWriter`). *"Every finalised line is written to disk as it happens, so clearing the on-screen log does not discard the record."* |
| `WhisperModels/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/` | WhisperKit's standard download layout. **Reuse this path** so existing downloads (3 GB here) carry over. |

`.wilco` is also a document type (`ShowFile: FileDocument`) for
import/export of shows, and `SubtitleFile: FileDocument` exports **SRT / VTT**.
A private UTI is used for channel drag-and-drop
(`ChannelDragToken`).

## 4. Data model (exact, from [meta]; JSON keys = property names)

All types are `Codable`; JSON key order in files is unordered (Swift
`JSONEncoder` default). Unknown keys must be tolerated; missing optional keys
default sensibly (0.2.0 has explicit `CodingKeys` + `init(from:)` for these).

```swift
struct ShowDocument {            // formatVersion == 1 in 0.2.0
  var formatVersion: Int
  var name: String               // default "New Show"
  var deviceUID: String?         // CoreAudio device UID; channels patch by UID
  var channels: [ChannelConfig]
  var groups: [ChannelGroup]
  var rules: [AutomationRule]
  var highlights: [HighlightRule]
  var destinations: [OSCDestination]
  var globalVocabulary: [String]
  var whisperModel: String       // WhisperModel raw value
  var mcpEnabled: Bool;  var mcpPort: UInt16      // default 8787
  var networkEnabled: Bool; var peerName: String
  var mosEnabled: Bool;  var mosHost: String; var mosPort: UInt16 // default 10540
  var mosID: String /* default "wilco" */;  var mosNCSID: String /* default "NCS" */
}

struct ChannelConfig {
  var id: UUID; var name: String
  var symbol: String             // SF Symbol, default "person.wave.2"
  var tint: ChannelTint
  var deviceChannel: Int?        // 0-based input on the device; nil = unpatched
  var groupID: UUID?
  var localeIdentifier: String   // e.g. "en_US"
  var engine: SpeechEngine
  var latencyProfile: SpeechLatencyProfile
  var isMuted: Bool              // still captured + metered, not transcribed
  var vocabulary: [String]       // per-channel custom terms
}
struct ChannelGroup { var id: UUID; var name: String; var symbol: String }

enum ChannelTint: String { red, orange, yellow, green, teal, cyan, blue, indigo, purple, pink, gray }
enum SpeechEngine: String { longForm, dictation, whisper }
enum SpeechLatencyProfile: String { leadAndCorrect, single }
enum WhisperModel: String { tiny, base, small, large }
  // → openai_whisper-tiny / -base / -small / -large-v3  (~75 MB / ~145 MB / ~470 MB / ~1.5 GB)
enum KeywordMatchMode: String { containsAny, containsAll, startsWith, regularExpression }

struct AutomationRule {
  var id: UUID; var name: String; var isEnabled: Bool
  var phrases: [String]; var matchMode: KeywordMatchMode
  var channelIDs: Set<UUID>      // empty = all channels [inferred]
  var cooldown: Double           // seconds
  var actions: [AutomationAction]
}
enum AutomationAction {          // Codable with nested per-case CodingKeys
  case osc(destinationID: UUID, address: String, arguments: [OSCMessage.Argument])
  case midi(endpointID: Int32, message: MIDIMessageSpec)   // CoreMIDI unique ID
  case webhook(urlTemplate: String, method: String, bodyTemplate: String)
  case notify(title: String, bodyTemplate: String)
  case markCuePoint(label: String)
}
enum MIDIMessageSpec {
  case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
  case noteOff(channel: UInt8, note: UInt8)
  case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
  case programChange(channel: UInt8, program: UInt8)
  case mscGo(deviceID: UInt8, cueNumber: String, cueList: String)  // MIDI Show Control
}
enum OSCMessage.Argument { case int(Int32), float(Float), string(String), bool(Bool) }

struct HighlightRule {
  var id: UUID; var name: String; var isEnabled: Bool
  var phrases: [String]; var matchMode: KeywordMatchMode
  var channelIDs: Set<UUID>; var tint: ChannelTint
}
struct OSCDestination {
  var id: UUID; var name: String; var host: String; var port: UInt16
  var transport: OSCTransport; var isEnabled: Bool
}
enum OSCTransport: String { udp, tcpLengthPrefixed, tcpSLIP }

struct TranscriptSegment {       // one line of Transcripts/*.jsonl
  var id: UUID; var channelID: UUID; var text: String
  var timestamp: Date            // ISO-8601, e.g. "2026-11-08T02:25:25Z"
  var sessionOffset: Double      // seconds since session start
  var isFinal: Bool; var confidence: Double?
  var matchedKeywords: [String]; var highlights: [SegmentHighlight]
}
struct SegmentHighlight { var phrase: String; var tint: ChannelTint }
```

Enums with associated values use Swift's **synthesized** `Codable` format —
the binary contains the compiler-generated per-case key enums
(`OscCodingKeys`, `MidiCodingKeys`, `MscGoCodingKeys { deviceID, cueNumber,
cueList }`, `IntCodingKeys`…) [meta]:

```json
{"osc":{"destinationID":"…","address":"/wilco/{channel}/go","arguments":[{"string":{"_0":"{text}"}}]}}
{"midi":{"endpointID":123,"message":{"mscGo":{"deviceID":1,"cueNumber":"5","cueList":"1"}}}}
```

Still worth confirming against a real show with rules before relying on it;
the user's current show has none.

## 5. Audio capture

`AudioCaptureEngine` drives one CoreAudio input device **directly via an
IOProc** (not AVAudioEngine) [meta: `procID`, `RTContext`, `AudioRingBuffer`]:

- The device is chosen by **UID** (`requestedUID`), so *"unplugging and
  replugging an interface restores the same patch."*
- Each channel = a `CaptureTap` routed (`RTRoute`: buffer index, channel in
  buffer, interleave count) into its own lock-free `AudioRingBuffer`; a level
  slot feeds the meters.
- **Self-healing:** a watchdog checks `secondsSinceLastCallback`; HAL property
  observers watch device list, sample rate and stream configuration
  (*"sample rate changed"*, *"stream configuration changed"*). On a stall or
  unplug the engine `rebuild(reason:)`s and increments `recoveryCount`
  (*"Reconnecting (attempt N)"*).
- `CaptureHealth` is shown in the status bar and via MCP: state, device name/UID,
  sample rate, channel count, recovery count, generation, dropped frames
  (*"Audio frames discarded because transcription fell behind"*), last error.

## 6. Transcription

Per channel, one `ChannelTranscribing` implementation:

| Engine | Implementation | Notes [str 18260–18270] |
|---|---|---|
| `longForm` | `SpeechTranscriber` (macOS 26) | *"Continuous speech model. Best for an open ring where people talk over each other. Downloads a model per language."* |
| `dictation` | `DictationTranscriber` (macOS 26) | *"Uses the dictation model macOS already has — no download, more languages. Tuned for short calls like 'standby' and 'go'."* |
| `whisper` | WhisperKit | One multilingual model shared by every Whisper channel (`WhisperModelManager` caches one `WhisperKit` per model). The only engine below macOS 26. |

`leadAndCorrect` latency profile (Apple engines): two analyzer "lanes" — a
fast **lead** pass shows italic volatile words, an accurate **anchor** pass
replaces them (*"Roughly twice the CPU per channel"*). `single` = one `sole`
lane. [meta: `TranscriberRole { lead, anchor, sole }`]

Vocabulary biasing = global vocabulary + channel vocabulary + every rule /
highlight phrase (*"Rule phrases are biased in automatically"*).
`SpeechAssetManager` installs per-locale assets with progress
(`LocaleStatus: unknown | unsupported | needsDownload | downloading(Double) | ready`).

## 7. Automation

`AutomationEngine.evaluate(segment:channelName:)` runs on each **final** segment:

1. For each enabled rule whose `channelIDs` is empty or contains the segment's
   channel, test phrases with `matchMode`.
2. Skip if fired within `cooldown` seconds (*"Cooldown suppresses repeat
   fires… a rule with no cooldown will fire a cue several times for one
   spoken standby."*).
3. `perform` each action with a `TemplateContext` and append an
   `ActivityEntry` (`fired` / `error` / `info`) to the Activity log.
4. Matched rule-lines are pushed to MOS if enabled (§10.3).

Highlights (`highlights(in:channelID:)`) only tint matching text.

**Templates** — `TemplateContext.expand` replaces `{text}`, `{channel}`,
`{keyword}`, `{time}`, `{offset}` [str/small-strings]. Defaults: webhook body
`{"channel":"{channel}","text":"{text}"}`, notification body `Heard on {channel}`.

**Built-in integration: Vor** (`IntegrationDescriptor`, getvor.app). Adds an
OSC destination (default host `127.0.0.1`) and starter rules
*Vor — Standby* (`/wilco/{channel}/standby`, phrases "standby", "stand by")
and *Vor — Go* (`/wilco/{channel}/go`), each with argument `{text}`.
Toggling it off removes the rules and destination. [str 18086, 27490–27497]

## 8. Run-of-show markers & post-show report

`MarkerDetector` classifies final lines into `ShowReport.MarkerCategory`
{ `phase`, `houseLights`, `song`, `cue`, `department` } using fixed phrase
lists and regexes — e.g. house-lights phrases (*"house lights out"*, *"house
to half"*…), song regex (*"top of the song"*, *"playback rolling"*…),
department "X go" regex, countdown regex (`\d{1,3} minutes? to`), phase labels
*Doors, Walk-in, Top of show, Downbeat, Blackout, Curtain, Intermission,
Encore, Show clear, Load out*. Exact lists: `reference/strings.txt` 18055–18080
and 27440–27490.

`ShowReportWindow` opens any past session (`ReportModel`, sessions =
`Transcripts/*.jsonl`) with tabs **Run of show / Chat log / Channels**,
search (`ShowReportSearch`) with channel and category filters, timeline bars
(`ShowReport.Bucket`), per-channel message/word stats, and **export to a
self-contained HTML page** (template with light/dark CSS, `<nav class="tabs">`)
and SRT/VTT subtitles.

## 9. User interface

Single main window (`MainWindowView`) — `NavigationSplitView`:

- **Sidebar** (`SidebarView`, `SidebarItem`: `combined | matrix | activity | channel(UUID)`,
  persisted in `sidebar.selection`): channel list with tint, symbol, state
  glyph, live meter, mute; groups; drag to reorder; *"Add a comms channel"*.
- **Detail**: `CombinedTranscriptView` (all channels interleaved),
  `ChannelMatrixView` (one resizable/collapsible column per channel; widths,
  font sizes and collapsed state persisted in `matrix.*` defaults),
  `ChannelTranscriptView`, `ActivityLogView`.
- **Inspector** (`inspector.visible`): `ChannelInspector` (name, tint, symbol,
  hardware channel, group, engine, locale, latency profile, model status,
  mute, meter, channel vocabulary, *Clear This Channel's Transcript*,
  *Delete Channel*) or `SessionInspector`.
- **Status bar** (`CaptureStatusBar`): capture state, device, rate, reconnects,
  dropped frames; Start/Stop capture.
- **Look & feel** defaults: `transcript.fontSize`, `.followLive`,
  `.showTimecode`, `.newestFirst`, motion style (`bouncy|snappy|smooth|still`,
  honours Reduce Motion).

**Settings** (`SettingsTab`, persisted `settings.selectedTab`): Look & Feel,
Audio, Languages (engine models, Whisper model picker, global vocabulary),
Automation (rules + highlights editors, test button), Destinations (OSC),
Integrations (Vor), Network (peers), MOS, MCP, License (→ remove).

All user-facing copy is in `reference/strings.txt`; reuse it where it reads well.

## 10. Network protocols

### 10.1 OSC out (`OSCSender`, actor)
One `NWConnection` per enabled destination. `OSCMessage.encoded()` is
standard **OSC 1.0**: padded address string, `,` + type tags `i` (Int32),
`f` (Float32), `s` (string), `T`/`F` (bool, no payload); numbers big-endian;
strings NUL-terminated and padded to 4 bytes. [dis 0x100113df0]

`OSCSender.frame(_:for:)` [dis 0x100118e5c]:
- `udp` — raw packet.
- `tcpLengthPrefixed` — 4-byte **big-endian** length, then packet (OSC 1.0 stream).
- `tcpSLIP` — **double-END SLIP** (OSC 1.1): `C0`, packet with `C0→DB DC` and
  `DB→DB DD`, `C0`.

Send failures are counted in `droppedMessages` and surfaced as `lastError`.

### 10.2 MIDI out (`MIDISender`)
CoreMIDI client and output port both named "Wilco" ("Wilco Out"); sends to a
destination by CoreMIDI unique ID (`Int32`). Note On (`0x9n`), Note Off
(`0x8n`), CC, Program Change. **MSC GO** via SysEx
(`mscGoPayload` [dis 0x1000ed9f8]):

```
F0 7F <deviceID & 0x7F> 02 01 01 <cue number, ASCII> 00 <cue list, ASCII> F7
        sub-ID MSC ─┘  │  └ command 01 = GO
                       └ command format 01 = Lighting (General)
```

### 10.3 MOS (`MOSDevice`)
TCP client to the NCS at `mosHost:mosPort` (default 10540, the MOS "lower" port).
Messages are `<mos><mosID>…</mosID><ncsID>…</ncsID><messageID>n</messageID>…</mos>`;
on connect sends `<reqMachInfo/>`; periodic `<heartbeat><time>yyyy-MM-dd'T'HH:mm:ss.SSS</time></heartbeat>`;
`push(slug:abstract:)` sends a `<mosObj>` with `objID`, `objSlug`,
`mosAbstract`, `objType DATA`, `objTB 0`, `objDur 0`, `status NEW`. Only
rule-matched lines are pushed.

⚠️ 0.2.0 encodes MOS text as **UTF-8** [dis: `String.data(using: .utf8)`]. The
MOS protocol specifies **UCS-2 / UTF-16 big-endian**, so strict NCS systems
may reject it. Likely a latent bug; make the encoding selectable in the rebuild.

### 10.4 Peer sharing (`PeerNetwork`)
- Bonjour **`_wilco._tcp`**, `NWListener` on any port with
  `Service(name: peerName, type: "_wilco._tcp", domain: nil, txtRecord: nil)` —
  **no TXT record**. [dis 0x10011c610]
- `instanceID = UUID().uuidString` per launch; `NWBrowser` discovers peers,
  one outbound `NWConnection` per discovered service; inbound connections are
  accepted by the listener and read.
- **Wire format: newline-delimited JSON.** `PeerCodec.encode` = `JSONEncoder`
  (`dateEncodingStrategy = .iso8601`) + one `0x0A`; `PeerCodec.drain` splits
  a per-connection buffer on newlines and decodes each `PeerLine`.
  [dis 0x10012cd40, 0x10012d25c]
- `PeerLine { peerID, peerName, channelID, channelName, tint, text,
  sessionOffset, timestamp, confidence? }`.
- Remote channels appear for reference only and **never fire local
  automation**. Text only, never audio.

### 10.5 MCP server (`MCPServer`)
Plain HTTP/1.1 on `NWListener` bound to **127.0.0.1:`mcpPort`** (default 8787),
MCP Streamable-HTTP style JSON-RPC 2.0 over `POST` (other methods → `405`).
Responses: `Content-Type: application/json`, `Connection: close`,
`Access-Control-Allow-Origin: *`. Handles `initialize`, `ping`,
`tools/list`, `tools/call`, `resources/list` and `prompts/list` (empty), and
notifications (→ `202 Accepted`). Errors: parse error, invalid request,
`Method not found: …`, `Missing tool name.`, `No channel named …`.

| Tool | Returns |
|---|---|
| `wilco_status` | `MCPStatus { capturing, device?, sampleRate?, reconnects, droppedFrames, channelCount, showName }` |
| `wilco_channels` | `[MCPChannel { id, name, patched, muted, transcribing, engine, language }]` |
| `wilco_transcript` | `[MCPLine { channel, sessionOffsetSeconds, time, text, confidence? }]`, oldest first; args `channel` (string, optional filter) and `limit` (integer, default 50, max 500) |

## 11. Known bugs in 0.2.0

### 11.1 Crash when deleting a channel (2026-11-07 22:25:48)
- Crash report: `EXC_BREAKPOINT / SIGTRAP` on the main thread in
  `ChannelInspector.body.getter + 664` (`main binary +0xc0410`) while an `NSAlert`
  sheet was closing. [file: `reference/crash-2026-11-07-222548.ips`]
- `ChannelInspector` stores **`let index: Int`** into `document.channels` [meta].
- At `0x1000c0300…0x1000c030c` the body checks `index >= 0` and
  `index < channels.count`; the failing branch jumps to `brk #1` at
  **`0x1000c0410` — the exact faulting address**. [dis]
- Sequence: *Delete Channel* confirmation removes the channel; SwiftUI
  re-renders the still-mounted inspector with the stale index → array index
  out of range → trap.
- **Rebuild rule:** inspectors and rows identify channels by `UUID`, resolve
  with `firstIndex(where:)`/a binding lookup, and render *Nothing Selected*
  when the ID no longer exists. Clear the selection before deleting.

## 12. Rebuild decisions (not observed — ours to make)

- Bundle ID `io.github.ic3burg.wilco`; data in
  `~/Library/Application Support/Wilco/`.
- Keep `formatVersion` 1 compatibility for `.wilco` files and `.jsonl` transcripts.
- Sparkle with a real appcast + EdDSA key; no TurboActivate.
- Ship a universal (arm64 + x86_64) build only if needed; 0.2.0 was arm64-only.

## 13. Open questions / not yet verified

- Confirm the `AutomationAction` JSON shape with a saved show that has rules.
- `{time}` / `{offset}` formatting in templates (cosmetic; choose our own).
- How a peer filters out its own advertisement (likely by service name;
  we're free to add a TXT `id=<instanceID>` while staying wire-compatible).
- Whisper chunking/VAD parameters and Apple analyzer options (tuning; can be
  re-derived empirically).
- Exact SwiftUI layouts (screenshots of 0.2.0 running are the best reference).
