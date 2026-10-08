# AGENTS.md

Burnrate: a macOS 26 menu bar app, window and desktop widget showing AI service limits, balances
and spend (Claude Code, Codex, OpenRouter, Replicate, Higgsfield). Swift 6.2, SwiftUI, WidgetKit,
Swift Testing. SwiftPM only (`mac/Package.swift`), no Xcode project, no third-party packages.

## Targets

- `BurnrateCore`: the engine (providers, scheduler, history, month total, API-price estimate, config,
  widget snapshot) and the `Store` the views observe. No SwiftUI import.
- `Burnrate`: the SwiftUI app: window, menu bar extra, settings, snapshot debug mode.
- `BurnrateWidget`: WidgetKit extension, built by SwiftPM with `-e _NSExtensionMain` and packed by
  `mac/build-app.sh` into `Contents/PlugIns/BurnrateWidget.appex`.
- `burnratectl`: the engine from the terminal: `check`, `dump [-demo]`, `init`, `-config DIR`.
- `BurnrateCoreTests`: Swift Testing suites; fixture in `mac/Tests/BurnrateCoreTests/Fixtures`.

## Commands

```bash
make test                 # swift test --package-path mac
make lint                 # swift format lint --strict (rules in .swift-format)
make format               # swift format -i
make mac                  # build release, pack mac/dist/Burnrate.app + bin/burnratectl
make mac-run              # open the built app
make mac-run-demo         # open Burnrate.app --args -demo YES: fake data, no accounts touched
make mac-install          # ditto to ~/Applications (APP_DIR=...)
make install              # burnratectl to ~/.local/bin (PREFIX=...)
make check                # build, then burnratectl check
scripts/install.sh        # the whole install; scripts/uninstall.sh [--purge]
```

UI checks without a screen session: `open mac/dist/Burnrate.app --args -demo YES -snapshot /tmp/w.png`
writes `w.png` (window), `w-menu.png` (Cyberpunk) or `w-menu-light.png` + `w-menu-dark.png` (Boring)
and `w-icon.png` and `w-settings-{general,appearance,providers}.png` after 8 s (`-snapshotDelay N`). `-look boring|cyberpunk` picks the look for that
launch, `-snapshotScheme light|dark` Boring's scheme, `-snapshotWidth N` lays the window out at N pt
(1016, 1470, 1728: laptop widths). `w-frame.png` is the whole window with its toolbar (glass comes out
flat) and `w-frame.txt` its toolbar height; `-snapshotSwitch YES` then flips the look live and writes
`w-switched.*` (without `-look`, which pins the look for the launch). `-snapshot`/demo runs exit at once if another
Burnrate (same bundle id) is running: quit the installed app first. CI (`.github/workflows/ci.yml`) runs lint, test,
`make mac` and `bash -n` on the scripts on `macos-26`.

## Conventions

- Import the module and use short names; qualify (`SwiftUI.Color`) only when two imported modules clash.
- `BurnrateCore` stays free of SwiftUI; formatting shared by looks lives there (`Format`, `MenuSummary`).
- Boring views in `mac/Sources/Burnrate/Views/Boring/`, Cyberpunk views in `mac/Sources/Burnrate/Views/`.
  The widget mirrors that split in `BoringWidget.swift` and `CyberWidget.swift`.
- Comments explain why, one short header per file; match the density around you, no doc-comment walls.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`); inject `Deps` (transport, exec, clock), never
  the network or real credentials. `APICostTracker(..., network: false)` in tests.
- Run `make lint test` before committing. `make format` fixes layout.
- Commit messages: imperative subject, body says why.

## Architecture

- The engine runs in process; there is no server, port or web page (`docs/adr/0001`).
- Credentials are the ones the user's CLIs already hold; Burnrate re-reads, never refreshes, and
  scrubs tokens from every message (`docs/adr/0002`).
- Two looks over one `Store`, chosen by `Look` in UserDefaults and carried into the widget snapshot
  (`docs/adr/0003`).
- History is append-only JSONL per source under Application Support (`docs/adr/0004`).
- The widget reads a JSON file through a home-relative read-only entitlement, no App Group
  (`docs/adr/0005`).
- Settings (⌘, or the panel's gear) patches `config.json` and restarts the engine
  (`AppModel.reload`); API keys live in the Keychain via `/usr/bin/security`, so rebuilds never
  prompt (`docs/adr/0006`). UI-only prefs are UserDefaults keys in `Prefs`.

Data flow: `Config.load` (config.json, `env_file`, Keychain) → `Engine.items` builds providers → `Scheduler` polls each on its interval
and yields `Update`s → `Store` (MainActor) replaces sources in place → views. `AppModel.feedWidget`
writes `WidgetSnapshot` to `~/Library/Application Support/burnrate/widget.json`.

## How to extend

- New provider: a `struct` conforming to `Provider` in `BurnrateCore/Providers/` (`name`, `title`,
  `link`, `note`, `fetch()` returning a `Snapshot`; throw `ProviderError.auth` with an uppercase hint
  when a login is missing). Register it in `Engine.items`, add a default interval in
  `Config.defaultProviders` and `Config.order`, a short name in `MenuSummary.short`, a symbol in
  `Boring.symbol` and `BoringWidget.symbol`, a `Demo` entry, and a test in `ProviderTests` with canned
  responses. A key it needs goes in `Keychain.names` and gets a `SecretRow` in `ProvidersPane`.
- New metric: a `Meter` (`kind` percent | money | credits, `dir` used | left, `resetAt`, `window`) in
  the snapshot's `gauges`; a text line is a `Fact`. Day-plus `percent`/`used` meters get a pace
  forecast for free (`Pace.fill`).
- New widget field: add it to `WidgetSnapshot` (Codable, keep old fields decodable), fill it in
  `WidgetSnapshot.init(sources:)`, render it in both widget looks.
- New look: a case in `Look`, a root view in `RootView`, a panel in `MenuPanel`, a widget branch in
  `LimitsView`, a `Theme`-like palette; the snapshot's `look` string names it.

## Boundaries

- No new dependencies without asking; the toolchain is enough.
- Never log, print or commit tokens, keys or cookies. Anything user-facing from a provider goes
  through `Scrub.text`. Test fixtures use fake values.
- No network in tests. No reads of real `~/.claude`, `~/.codex` or the Keychain in tests:
  `Config.load(dir, keychain: nil)` or a `FakeKeychain`.
- No App Group, no Team-ID-bound entitlements: ad-hoc builds have no Team ID.
- Do not rename `~/.config/burnrate`, the Application Support dir, `widget.json` or the history file
  format once released without a migration (none exist yet: nothing was shipped).
- The widget only displays; no buttons, no refresh, no network (a user decision).
- Do not add a web page or a server back.

## Widget pitfalls

- Without `-e _NSExtensionMain` the extension exits with code 0 and never shows in the gallery.
- The extension must be sandboxed (`Widget.entitlements`), signed before the outer bundle.
- It launches from `~/Applications` after the app ran once; a bundle under a hidden directory
  (`.claude/worktrees/...`, a build dir) fails to launch. `pluginkit -a <appex>` registers, `-r` removes.
- Debug with `/usr/bin/log stream --predicate 'process == "chronod" OR process == "BurnrateWidget"'`;
  `log` alone is a zsh builtin. chronod's "purging instead because we shouldn't cache it" is normal.
- The system allows a few dozen reloads a day: the app calls `reloadAllTimelines` only when the
  alert level or look changes or 15 min passed. Keep it that way.
- The Cyberpunk widget needs its own copy of JetBrains Mono: the sandbox cannot read the app's.
