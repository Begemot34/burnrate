# 6. Settings window and keys in the Keychain

Status: Accepted (2026-10-08)

## Context

Providers, intervals, subscription prices, keys, the pace forecast and the warning thresholds
need a place to change them without editing files. A macOS app is expected to have a Settings
window (⌘,); third-party apps cannot add a pane to System Settings. Keys in a dotfile are plain
text and travel with backups and dotfile repos.
The build is ad-hoc signed: a Keychain item created through Security.framework trusts the
exact binary, so every rebuild would ask "allow access", and the data protection keychain
needs a Team ID.

## Decision

- The SwiftUI `Settings` scene with General, Appearance and Providers panes, also opened from the
  menu bar panel (activation policy `.regular` first, or an accessory app's window opens behind).
  Changes apply at once: `Config.save` patches `config.json` (unknown keys stay) and
  `AppModel.reload` restarts the engine; the store drops cards of providers switched off.
- UI-only choices (look, pace forecast) are UserDefaults; anything the engine or `burnratectl`
  needs (providers, prices, thresholds) is in `config.json`. Thresholds are stamped on each
  `Meter` by the scheduler, so the app, the panel and the widget colour alike.
- Keys are generic passwords, service `burnrate`, account the variable name, created, read and
  deleted only through `/usr/bin/security` (`Keychain`); the value goes in on stdin through
  `security -i`, never in argv. Such an item trusts Apple's tool (partition `apple-tool:`), so
  neither a rebuild nor `burnratectl` prompts. `env_file` is read too; the Keychain wins.
- No automatic import of browser cookies: it would prompt for "Chrome Safe Storage" every time.

## Consequences

- No prompts, ever; the trade-off is that any process running as the user can read the keys
  with `security find-generic-password -s burnrate -w`, as it could read a 0600 file.
- Tests never touch the Keychain: `Config.load(keychain:)` takes the runner, tests pass a fake.
- A new provider with a key adds its variable to `Keychain.names` and a row in `ProvidersPane`.
