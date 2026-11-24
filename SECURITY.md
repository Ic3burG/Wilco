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

## Supported versions

Only the latest build from `main` gets fixes.
