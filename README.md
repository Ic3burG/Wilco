# Wilco

[![CI](https://github.com/Ic3burG/Wilco/actions/workflows/ci.yml/badge.svg)](https://github.com/Ic3burG/Wilco/actions/workflows/ci.yml)

Live comms transcription for show control on macOS. Wilco captures every
channel of a multichannel audio interface (Dante, MADI, USB), transcribes each
one on-device, and fires OSC, MIDI, webhook and notification actions when
phrases like "Standby" or "Go" are heard on comms. After the show it builds a
post-show report of every call.

## Status

The core app works and is in testing; it is not yet released. See
[`docs/PROGRESS.md`](docs/PROGRESS.md) for the session-by-session log.

| Working | Still to rebuild |
|---|---|
| Show editor; import and export of `.wilco` shows | Peer sharing between Macs (`_wilco._tcp`) |
| Multichannel, multi-device capture with meters and auto-recovery | MCP server |
| On-device transcription (Apple speech on macOS 26+, Whisper, Parakeet with vocabulary and live preview) | MOS |
| Automation: OSC, MIDI, webhooks, notifications, cue markers | Automatic updates (Sparkle) |
| Post-show report with HTML, SRT and VTT export | Vor preset |
| Appearance, including Light / Dark / Match System | |
| Settings in one sidebar window: This Show (numbered setup steps with ticks) and This Mac, with search (new; tested, not yet tried in the app) | |
| Configurations: saved show setups, load in one click, import/export (new) | |
| Multichannel transcription benchmark, `wilco-bench` (see `docs/BENCHMARK.md`) | |
| Voice letters: who's speaking within an exchange, in the transcript and reports (new) | |
| Report markers editable per show, with presets (built-in Concert, Corporate, Theatre) and a Talkback category (new) | |
| Post-show Review: findings, one-click fixes, vocabulary suggestions and trends across shows; per-minute session diagnostics (levels, dropouts, music/singing) behind its quiet, music, level and lost-audio checks (new) | |
| Learning from shows (opt-in): keeps unclear lines and exchanges as clips, labels them on the Mac after the show by model agreement, and scores the hardest lines in the Review and `wilco-bench --real-show` (new; tested, not yet tried in the app) | |
| Security model (`docs/SECURITY-MODEL.md`) with guardrail and hostile-file tests in CI: imported shows can't send or share on their own, damaged files can't crash the app (new; tested, not yet tried in the app) | |

## Files

- Shows are `.wilco` files (JSON, `formatVersion` 1) and transcripts are
  `.jsonl`, one line per finalised segment, with a `.wilco` copy of the
  show each session was recorded with beside it. Both live in
  `~/Library/Application Support/Wilco` along with downloaded Whisper models.
- New show fields always get defaults, so older files keep opening.

## Building

Requires macOS 15 or later and Xcode 26 or later.

- **App:** open `Wilco.xcodeproj` and run the **Wilco** scheme. Set your own
  team under *Signing & Capabilities* if you are not building as the
  maintainer.
- **Tests:** `cd Packages/WilcoCore && swift test`. Tests that need a real
  show or real transcripts skip themselves when that data isn't present;
  `WILCO_ASR_TESTS=1 swift test` also runs real speech recognition.

## Layout

| Path | Contents |
|---|---|
| `Wilco/` | The SwiftUI app |
| `Packages/WilcoCore` | Model, audio capture, transcription and control, each its own target with tests |
| `Config/` | Info.plist and entitlements |
| `docs/SPEC.md` | Data formats, protocols, UI and known bugs |
| `docs/PROGRESS.md` | Work log, updated at the end of every session |

## License

Copyright © 2026 Omar Davis.

Wilco is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; see [`LICENSE`](LICENSE) for the full terms.

Anyone who distributes Wilco, or a changed version of it, must release the
source under the same license. Its dependencies (WhisperKit, FluidAudio,
Sparkle, Swift Argument Parser) are under MIT or Apache-2.0 licenses, which
are compatible with GPL-3.0.
