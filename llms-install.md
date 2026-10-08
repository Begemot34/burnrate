# Installing Burnrate (guide for coding agents)

You are installing Burnrate, a macOS menu bar app, window and desktop widget that shows AI service
limits and balances. Source: https://github.com/Begemot34/burnrate. Everything below runs as the
current user, without sudo. Follow the steps in order. Never print, paste or echo API keys, tokens or
cookies.

Ask the user for one go-ahead before the clone and the install script (or `make mac-install
install`), showing the commands first: the clone creates `~/.local/src/burnrate`; the script quits a
running Burnrate, writes outside the clone, registers the widget and launches the
app. The read-only checks need no confirmation.

Two locations are used throughout. Use the defaults unless the user asks otherwise, and use the same
values in every later command (also uninstall). Your shell state may not persist between commands,
so set them at the start of each command that uses them:

```bash
APP_DIR="$HOME/Applications"   # where Burnrate.app goes; the widget is only registered for ~/Applications
PREFIX="$HOME/.local/bin"      # where burnratectl goes
```

## Goal

At the end: `$APP_DIR/Burnrate.app` is installed and running, `$PREFIX/burnratectl` works,
`~/.config/burnrate/` holds the user's configuration, and the user knows how to add the widget.

## 1. Prerequisites

Run each check in this order. If one fails, stop and tell the user what is quoted.

```bash
sw_vers -productVersion
```
The major version must be 26 or newer. Otherwise: "Burnrate needs macOS 26 or newer; this Mac
runs `<version>`. It cannot be installed here."

```bash
xcode-select -p
```
Must print a path. Otherwise: "The Command Line Tools are missing. Run `xcode-select --install`
yourself (it opens a GUI dialog), then tell me to continue." Do not run it, and do not run `git`,
`make` or `xcrun` before this check passes: on a Mac without the tools they open that dialog.

```bash
xcrun swift --version
git --version
make --version
```
`swift` must report version 6.2 or newer (Xcode 26 or matching Command Line Tools), and `git` and
`make` must succeed. Otherwise: "The toolchain is too old or incomplete; update Xcode from the App
Store or the Command Line Tools in System Settings ▸ Software Update, then tell me to continue."

The build needs no network: the fonts are in the repository.

## 2. Clone

```bash
mkdir -p ~/.local/src
git clone https://github.com/Begemot34/burnrate.git ~/.local/src/burnrate
```

If `~/.local/src/burnrate` already exists and is a git checkout, update it instead:

```bash
git -C ~/.local/src/burnrate pull --ff-only
```

If it exists but is not a git checkout (no `.git`), stop and tell the user. Do not delete or
overwrite it; suggest moving it away, or setting `BURNRATE_SRC` to another path for the script.

## 3. Build and install

After the user's go-ahead. Preferred: the install script from the clone. It checks the prerequisites
again, quits a running Burnrate, builds in release mode, writes
`$APP_DIR/Burnrate.app` and `$PREFIX/burnratectl`, registers the widget with `pluginkit` (only when
`APP_DIR` is `~/Applications`) and opens the app. Run from a clone, it builds that clone as it is and
does not pull.

```bash
cd ~/.local/src/burnrate && APP_DIR="$APP_DIR" PREFIX="$PREFIX" ./scripts/install.sh
```

Environment variables, all optional:

- `PREFIX`: where `burnratectl` goes. Default `~/.local/bin`.
- `APP_DIR`: where `Burnrate.app` goes. Default `~/Applications`. Keep the default unless the user
  insists: the widget is only registered for `~/Applications`.
- `BURNRATE_NO_OPEN=1`: do not launch the app at the end (then the open in step 4 is needed).

The first build takes a few minutes. If the script ends with a warning that `$PREFIX` is not on
`PATH`, tell the user to add `export PATH="$PREFIX:$PATH"` to their shell profile, or offer to
append it to `~/.zshrc` and show the exact line first.

Equivalent manual steps, if the script cannot be used:

```bash
cd ~/.local/src/burnrate && make mac mac-install install APP_DIR="$APP_DIR" PREFIX="$PREFIX"
```

Note what the result is: an ad-hoc signed build (`codesign -s -`), not notarized. It runs on this Mac
because it was built here. It cannot be copied to another Mac.

## 4. Verify

```bash
"$PREFIX/burnratectl" check
```
Prints one row per source. `FAIL` rows with hints like `NO OPENROUTER KEY — ADD IT IN SETTINGS ▸ PROVIDERS` or
`NO CLAUDE CODE LOGIN IN KEYCHAIN` are expected before configuration; a row that says `ok` for a
service the user is logged in to means that card works.

```bash
pgrep -x Burnrate >/dev/null && echo running || open "$APP_DIR/Burnrate.app"
```
The app shows a window and a menu bar item. Closing the window keeps the menu bar item; ⌘O or
"Open Window" in the panel brings it back.

## 5. Configure

The app writes `~/.config/burnrate/config.json` on first launch (`"$PREFIX/burnratectl" init` does the
same without the app). Explain to the user, without asking for the values:

- Claude Code and Codex need no keys. They use the login of the `claude` and `codex` CLIs on this
  Mac. If a card shows a login hint, the user runs `claude` or `codex login` once.
- OpenRouter needs `OPENROUTER_API_KEY`. Replicate needs only `REPLICATE_SESSIONID` (the
  `sessionid` cookie from replicate.com), no API token. Higgsfield needs its CLI
  logged in (`higgsfield login`).

Ask the user to enter the keys themselves in Burnrate's Settings ▸ Providers (⌘,); they are
stored in the login Keychain. From a terminal the user can run
`burnratectl secret set OPENROUTER_API_KEY` and type the key on stdin. Do not ask them to paste keys
into the chat and do not set keys for them. Keys in `~/.config/burnrate/.env` (the `env_file` of
`config.json`) are read too; the Keychain wins on conflicts.

Optional edits in `config.json`: set `"enabled": false` for a service the user does not use,
`"monthly_usd"` to override a subscription price, `"unofficial": true` under `codex` to also read
per-model availability from chatgpt.com with the local Codex token.

Afterwards run `"$PREFIX/burnratectl" check` again, then ⌘R in the app ("Refresh All") or wait for
the next poll.

## 6. Widget

Tell the user: right-click the desktop ▸ Edit Widgets ▸ search "Burnrate" ▸ add the small or medium
widget. It appears in the gallery once the app sits in `~/Applications` and has run once. The widget
only reads `~/Library/Application Support/burnrate/widget.json`, which the app writes; it needs the app
running to stay fresh and marks itself stale after 30 minutes without it.

## Troubleshooting

- "Burnrate.app is damaged" or Gatekeeper refuses to open it: the bundle was copied from elsewhere or
  carries a quarantine flag. Rebuild on this Mac with the install script. Never suggest disabling
  Gatekeeper.
- `xcrun: error: unable to find utility "swift"` or `swift: command not found`: Command Line Tools or
  Xcode are missing or not selected. The user installs them (see Prerequisites); then
  `xcode-select -p` should print a path.
- Widget not in the gallery: confirm `ls "$APP_DIR/Burnrate.app/Contents/PlugIns/"` shows
  `BurnrateWidget.appex`, run `open "$APP_DIR/Burnrate.app"`, then
  `pluginkit -a "$APP_DIR/Burnrate.app/Contents/PlugIns/BurnrateWidget.appex"` and reopen Edit
  Widgets. An app installed anywhere other than `~/Applications` (or under a hidden directory) will
  not provide the widget.
- `burnratectl: command not found`: `$PREFIX` is not on `PATH`; use the full path or add it to
  the shell profile.
- A card says `FROM LOCAL SESSION LOG`: the `codex` CLI was not found or failed; Burnrate is reading
  the newest Codex session log instead. The user installs or logs in to Codex.
- Config errors show a banner in the app instead of the cards; the message names the bad field in
  `config.json`.

## Uninstall

```bash
export APP_DIR PREFIX    # the values used for the install
~/.local/src/burnrate/scripts/uninstall.sh            # app and burnratectl; config and history stay
~/.local/src/burnrate/scripts/uninstall.sh --purge    # also ~/.config/burnrate, the data, preferences and Keychain keys
```

Ask before `--purge`: it deletes the user's keys file and history. The scripts read the exported `PREFIX` and `APP_DIR`. The clone in `~/.local/src/burnrate` can be deleted afterwards.
