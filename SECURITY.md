# Security

## Reporting a problem

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/Ic3burG/Wilco/security/advisories/new)
rather than in a public issue. Include what you found, how to reproduce it and
which version or commit you tried.

## What Wilco does with your data

- Audio is transcribed on the Mac and never leaves it.
- Wilco only sends what you set up yourself: OSC and MIDI messages, webhooks
  and notifications fired by your automation rules.
- Text heard on comms is treated as untrusted. It is escaped before it goes
  into OSC addresses, URLs, JSON bodies and HTML reports.
- Show files can come from anyone. When you import one, rules that would
  send what's heard to another machine (webhooks, or OSC beyond your local
  network) arrive turned off until you turn them on.
- Files are checked as they are read, so a damaged or hand-edited show or
  transcript can't crash the app.
- Webhooks go only to the address in the rule: redirects are not followed.

The full security model, with the rules new features follow, is in
[`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md).

## Supported versions

Only the latest build from `main` gets fixes.
