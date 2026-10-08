# 4. History as append-only JSONL

Status: Accepted (2026-10-07, kept through the Swift port)

## Context

The sparkline, burn per hour, run-out and the Higgsfield month estimate need a time series per
source. Burnrate polls every few minutes, so the series is small (hundreds of points a day), has
one writer (the app) and one occasional reader (`burnratectl dump`). A database or a binary
format would be more than the data asks for and harder to inspect when a card looks wrong.

## Decision

One file per source, `~/Library/Application Support/burnrate/history/<name>.jsonl`, one line
`{"t":<unix ms>,"v":<value>}` per successful poll, appended with `FileHandle`, created `0600`
in a `0700` directory. On load the last 35 days are kept in memory (a full calendar month for the
month-drop estimate); the file itself is never rewritten. `burnratectl dump` opens the store
read-only so it can run beside the app. The Go version used the same lines, and the Swift port
kept them (`HistoryStore.goFloat` reproduces Go's float formatting).

## Consequences

- Readable with `tail`, `jq` and a text editor; a corrupt line is skipped, not fatal.
- Append is one syscall; no schema, no migrations, no locking beyond the single-instance app.
- Files grow without compaction. At one point per poll that is a few MB a year per source;
  acceptable, revisit if intervals shrink.
- One series per source, the value the provider picks (5h window or balance); nothing else has history.
- Once released, renaming the directory or changing the line format needs a migration.
