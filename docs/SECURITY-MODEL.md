# Security model

How Wilco stays safe, and what every new feature has to respect. Read this
before adding anything that reads a file, talks to the network, runs on
what was heard, or shows text from a show or from speech.

`SECURITY.md` at the top of the repository is the short public version and
says how to report a problem.

## 1. What we protect

1. **What is said on comms.** Audio and transcripts are private to the
   production. Audio never leaves the Mac. Text leaves only through
   actions the operator set up and can see.
2. **The show.** Wilco runs during live shows. A crash or a frozen window
   loses comms, and a wrong OSC or MIDI message can fire a real cue.
3. **The operator's Mac.** Wilco must not become a way to run code on it,
   read other files, or listen on the network.
4. **The private reference material.** `reference/` and the reference
   app's name never reach the public repository.

## 2. What we don't trust

| Input | Why it isn't trusted |
|---|---|
| Speech | Anyone on comms decides what the text says. |
| `.wilco` show files | Crews pass them around. A file can be written by anyone. |
| Transcripts, diagnostics, clips, presets on disk | Can be corrupt (a crash mid-write) or edited. |
| Network peers and local web pages | Anything that can reach a port can send to it. |
| Servers Wilco talks to (webhooks, consoles) | Can answer with anything, of any size. |
| Downloaded speech models | Come from a third-party host. |
| Dependencies and CI actions | Other people's code with our access. |
| Environment variables | Inherited from whatever launched the app. |

The operator is trusted. So is anything already running as the operator's
user: Wilco can't defend against that and doesn't try.

## 3. Where the checks sit

```
 file on disk ──► WilcoJSON decode ──► FileRepair ──► the rest of the app
 show from someone else ──► import ──► OutboundRules (rules off, sharing off)
 speech ──► text ──► KeywordMatcher (bounded) ──► TemplateContext (escaped) ──► OSC / webhook / MIDI
 text ──► ShowReportHTML.escape + content security policy ──► exported page
```

Checks happen once, at the edge. Code past the edge may rely on them, and
code that adds a new edge adds the same checks.

## 4. The rules

Each rule says how it is enforced. "Guardrail" means a test in
`SecurityGuardrailTests` that reads the source and fails when the rule is
broken. Fixing a guardrail failure by adding a file to its list is only
right when the work the rule asks for has been done in the same change.

### 4.1 Files never crash the app

Swift stops the program on an out-of-range number conversion, an array
index past the end, or a dictionary built from repeated keys. So:

- Decode files only through `WilcoJSON`. (Guardrail: *Decoding files*.)
- Every file type is repaired as it is read (`FileRepair.swift`): numbers
  are held within `FileLimits`, IDs are made unique. A new format, or a new
  number in an old one, gets its repair there.
- Convert a `Double` that came from outside with `Int(safely:)`.
- No `try!`, `as!` or `fatalError` on a path data can reach. (Guardrail.)
- Use `Dictionary(_:uniquingKeysWith:)`, not `uniqueKeysWithValues`, unless
  the keys were made unique by `FileRepair`. (Guardrail.)
- Build paths to write or delete from a UUID or a fixed name inside
  Wilco's folder, never from text in a file. (Guardrail: *Deleting files*.)
- Import refuses show files over 20 MB.
- Enforced by `HostileInputTests`: hand-written hostile files plus seeded
  mutation of the real fixtures, run through decoding, reports, exports,
  review, sidebar editing and rule evaluation. Add the new format to it.

### 4.2 A show from someone else can't act on its own

- On import, rules that send what is heard elsewhere arrive turned off:
  any webhook, and OSC to a host outside the local network
  (`OutboundRules`). The operator is told which rules and which hosts.
- On import, sharing switches (`mcpEnabled`, `networkEnabled`,
  `mosEnabled`) are turned off. Opening a listener or starting to send is
  this Mac's choice, never the file's.
- A new kind of action that sends data, and a new setting that opens a
  port or contacts a host, must be added to `OutboundRules` with a test.
- Hosts are judged the way the system resolver reads them (`inet_aton`),
  so `134744072` or `010.8.8.8` can't pass as local.

### 4.3 Sending

- Text from speech is escaped for where it goes: `TemplateContext` has an
  escaping mode for OSC addresses, URLs and JSON. A new destination format
  gets its own mode and tests. What is heard may fill a placeholder; it
  may never choose the host, the OSC address pattern or the HTTP method.
- All HTTP goes through `WebhookSender`: `http`/`https` only, methods from
  an allow-list, no cookies, cache or stored credentials, no redirects,
  and the response body is never downloaded. (Guardrail: *Outbound HTTP*.)
- All sockets go through `OSCSender`. (Guardrail: *Outbound sockets*.)
- Every send has a timeout and reports its outcome in the Activity log.

### 4.4 Listening and other ways in

Wilco has no listener, URL scheme, document type or drop target today.
(Guardrails: *Listening on the network*, *Wildcard CORS*, and the
Info.plist check.) Before adding one:

- It is **off by default** and switched on by the operator on this Mac.
- **MCP server:** bind to `127.0.0.1` only; no CORS header; reject requests
  whose `Host` isn't the loopback address and port, and any request with a
  browser `Origin`; require a per-install bearer token.
- **Peer sharing:** pair first (a code shown on one Mac, typed on the
  other), authenticate every line with the shared key, close unpaired
  connections.
- Cap the size of a message, the per-connection buffer and the number of
  connections. Drop a connection that breaks the rules.
- What arrives is untrusted like speech, and **never fires automation**.
- Spec §12.1 has the detail. The guardrail's allowed list is widened in
  the same commit as the tests for the points above.

### 4.5 Regular expressions

Patterns come from show files and run on every line, on the main thread.

- Only `KeywordMatcher` runs a pattern that came from data. (Guardrail.)
- It refuses long patterns and nested repeats, searches only the start of
  a very long line, and stops any search at `regexTimeLimit` (50 ms). A
  pattern that hits the limit is switched off until restart and reported.

### 4.6 Running programs and the environment

- The app never starts another program, script or dynamic library.
  (Guardrail: *Running other programs*.) The benchmark tool may, with an
  argument list and no shell.
- The app doesn't read environment variables (guardrail) and clears the
  ones its speech libraries would obey (`DownloadEnvironment`). When a
  dependency is updated, check for new variables it reads and add them.

### 4.7 Privacy

- Audio stays on the Mac. Speech uses on-device engines only; never
  `SFSpeechRecognizer`, which can send audio to a server.
- No logging in the app or its libraries: what is heard must not reach
  the system log. (Guardrail: *Logging*.) Errors go to the Activity log or
  an alert, and say what failed, not what was said.
- Nothing is sent that the operator didn't set up: no telemetry, no
  crash-report uploads, no update checks without `SUPublicEDKey`.
- Data lives under `~/Library/Application Support/Wilco`, which only the
  user's account can open.

### 4.8 Showing text

- Text from shows and speech is displayed as text. Never parse it as HTML,
  Markdown or attributed text, and never put it in a web view.
  (Guardrail: *Markup from text*.)
- The HTML report escapes every value (`ShowReportHTML.escape`) and
  carries a content security policy that allows only its own script, by
  hash, and no loading or sending. Change the script and the hash follows;
  the tests check both.

### 4.9 Memory and threads

- Raw pointers stay in the files that already use them. Bounds are proved
  before use and never come from a file. (Guardrail: *Raw memory*.)
- The audio callback doesn't allocate, lock or log, and only reads inputs
  validated before capture started (`CaptureRouting.plan`).
- `@unchecked Sendable` needs a comment saying why it holds. (Guardrail.)

### 4.10 Other people's code

- Dependencies are the listed ones. (Guardrail: *dependenciesAreTheKnownOnes*.)
  Before adding one: who maintains it, what it does on the network, what
  it reads from the environment, whether it logs.
- CI actions are pinned to commit SHAs and the workflow token is
  read-only. (Guardrail, and the repository's own settings.)
- Dependabot raises advisories and updates. Read the changes before
  merging; a pin only helps if what it points to was looked at.

### 4.11 The public repository

- Nothing under `reference/` but its README is tracked, and no keys,
  recordings, archives or app bundles. (Guardrail: *nothingPrivateIsTracked*.)
- The reference app is never named. On a Mac that has
  `reference/forbidden-words.txt` (untracked), a guardrail checks every
  tracked file for those words.
- GitHub secret scanning and push protection are on.

## 5. Checklist for a new feature

Answer these in the design or the pull request. "No" to all is a fine answer.

1. **Does it read anything new?** A file type, a field, a network message,
   a pasted or dropped item. → §4.1: decode through `WilcoJSON`, repair,
   add to `HostileInputTests`.
2. **Can a show file switch it on or point it somewhere?** → §4.2: add it
   to `OutboundRules`.
3. **Does it send anything?** → §4.3: which escaping mode, which sender,
   what the operator sees.
4. **Does it listen, or add a way in?** → §4.4, all of it.
5. **Does it use what was heard to decide something?** Then anyone on
   comms can decide it. Say what the worst spoken sentence does.
6. **Does it show text from a show or from speech?** → §4.8.
7. **Can it stall or crash the main thread on bad input?** → §4.1, §4.5.
8. **Does it add a dependency, an entitlement or an Info.plist key?**
   → §4.10 and the guardrails for settings.
9. **Does it write anything new to disk, or anywhere else?** → §4.7.

Then run `swift test` (the guardrails and hostile-input tests are part of
it) and `/security-review` on the change.

## 6. Before a release

- Release configuration, signed with the team's Developer ID, hardened
  runtime on, **no** `get-task-allow`, notarized and stapled.
- `codesign -d --entitlements -` shows only audio input.
- Updates: `SUPublicEDKey` set, feed over HTTPS, shipped as `.zip` or
  `.dmg`, never `.pkg`. Keep the EdDSA private key off the repository and
  off CI logs.
- Dependabot and secret-scanning alerts are empty.

## 7. Known limits

- **Not sandboxed.** Capturing several CoreAudio devices is the reason.
  The hardened runtime and the rules above are the defence; a bug in a
  dependency has the user's full access.
- **Models aren't pinned by hash.** They are fetched over HTTPS from the
  publisher's Hugging Face repository, and the size and hash checked are
  the ones that host reports. A compromised publisher account could ship a
  different model. A model is data, not code, but it decides what Wilco
  "hears".
- **The regex check is a net, not a proof.** The time limit is what
  bounds a slow pattern; the first slow line costs up to 50 ms.
- **A rule can still send to the local network when imported.** OSC to a
  console on the LAN stays on; that is what shows are made of.
- **Notifications** that include `{text}` show comms on the lock screen.
- **Anything running as the user** can read Wilco's files and settings.

## 8. Findings so far

| Date | Finding | Fix |
|---|---|---|
| 2026-11-24 | Repository settings: no secret scanning, Dependabot, branch protection or action pinning | All on; actions pinned |
| 2026-11-24 | Imported show could send every line to a remote webhook unnoticed | `OutboundRules` |
| 2026-11-24 | Numeric host forms passed as "local" | Hosts parsed with `inet_aton` / `inet_pton` |
| 2026-11-24 | Regex rule could freeze the window (nested repeats; overlapping alternatives) | Safety check, then a 50 ms limit |
| 2026-11-24 | Transcript line with a negative or huge time offset crashed the report | `FileRepair`, bounded buckets |
| 2026-11-24 | Show file with repeated IDs crashed sidebar editing | IDs made unique on decode |
| 2026-11-24 | Diagnostics file with far-apart minutes could exhaust memory | Minutes held within a session |
| 2026-11-24 | Show file could carry sharing switches set to on | Turned off on import |
| 2026-11-24 | Webhooks followed redirects, kept cookies and downloaded whole replies | `WebhookSender` |
| 2026-11-24 | Environment variables could move model downloads to another host | Cleared at launch |
| 2026-11-24 | HTML report relied on escaping alone | Content security policy by script hash |
