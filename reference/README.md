# Reference material (0.2.0)

Evidence used to write `docs/SPEC.md`. Not part of the rebuild's source.

| File | What it is |
|---|---|
| `app-0.2.0.app` | Byte-identical copy of the original app (SHA-256 of executable `6e92bf9e…0824f9`). Analyse this, never the installed copy in `/Applications`. |
| `crash-2026-11-07-222548.ips` | Crash report for the delete-channel crash (SPEC §11.1). |
| `sample-data/Current-0.2.0.json` | The user's real show file, for format-compatibility tests. |
| `swift-fields.txt` | Every Swift type's stored properties / enum cases, from `__swift5_fieldmd`. |
| `swift-members.txt` | Methods and computed properties per type, from the symbol table. |
| `swift-small-strings.txt` | Short (≤15 byte) string literals recovered per function. |
| `strings.txt` | All longer string literals (`strings -n 3`). Line numbers are cited in the spec. |
