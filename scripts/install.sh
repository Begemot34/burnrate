#!/usr/bin/env bash
# Builds Burnrate from source and installs the app and burnratectl. No sudo.
#   ./scripts/install.sh
#   curl -fsSL https://raw.githubusercontent.com/Begemot34/burnrate/main/scripts/install.sh | bash
# Writes: $APP_DIR/Burnrate.app, $PREFIX/burnratectl; quits a running Burnrate.
# Env: PREFIX      directory for burnratectl (default ~/.local/bin; the name is kept for `make install`),
#      APP_DIR     directory for Burnrate.app (default ~/Applications; the widget is only registered there),
#      BURNRATE_SRC  clone dir when run outside a clone (default ~/.local/src/burnrate),
#      BURNRATE_NO_OPEN=1  do not launch the app afterwards.
# Run inside a clone it builds that clone as it is (no pull); from curl it clones or updates BURNRATE_SRC.
set -euo pipefail

REPO_URL="https://github.com/Begemot34/burnrate.git"
PREFIX="${PREFIX:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
# no trailing slash, for the comparisons and messages below
while [[ "$PREFIX" != "/" && "$PREFIX" == */ ]]; do PREFIX="${PREFIX%/}"; done
while [[ "$APP_DIR" != "/" && "$APP_DIR" == */ ]]; do APP_DIR="${APP_DIR%/}"; done
export PREFIX APP_DIR

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Burnrate is macOS only"
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= 26 )) || die "macOS 26 or newer is required (this is $macos)"

# before any git/make/xcrun shim: those pop up a GUI installer when the tools are missing
xcode-select -p >/dev/null 2>&1 || die "Command Line Tools are not installed; run: xcode-select --install, then rerun this script"

swift_line="$(xcrun swift --version 2>&1 | head -n 2 | tr '\n' ' ')" || true
swift_ver="$(sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' <<<"$swift_line")"
[[ -n "$swift_ver" ]] || die "Swift toolchain not found; install Xcode 26 from the App Store, or run: xcode-select --install"
if (( ${swift_ver%%.*} < 6 || (${swift_ver%%.*} == 6 && ${swift_ver#*.} < 2) )); then
  die "Swift 6.2 or newer is required (found $swift_ver); update Xcode / the Command Line Tools"
fi
command -v make >/dev/null || die "make not found; run: xcode-select --install"

# inside a clone (this script lives in scripts/), or clone one. BASH_SOURCE is empty for curl | bash.
src=""
script_src="${BASH_SOURCE[0]:-}"
if [[ -n "$script_src" && -f "$script_src" ]]; then
  script_dir="$(cd "$(dirname "$script_src")" && pwd)"
  if [[ -f "$script_dir/../mac/Package.swift" ]]; then
    src="$(cd "$script_dir/.." && pwd)"
  fi
fi
if [[ -z "$src" ]]; then
  command -v git >/dev/null || die "git not found; run: xcode-select --install"
  src="${BURNRATE_SRC:-$HOME/.local/src/burnrate}"
  if [[ -d "$src/.git" ]]; then
    echo "==> updating $src"
    git -C "$src" pull --ff-only
  elif [[ -e "$src" ]] && [[ ! -d "$src" || -n "$(ls -A "$src")" ]]; then
    die "$src exists but is not a git checkout. Move it away or point BURNRATE_SRC at another path, then rerun. Nothing was deleted."
  else
    echo "==> cloning into $src"
    mkdir -p "$(dirname "$src")"
    git clone "$REPO_URL" "$src"
  fi
fi
cd "$src"

if pgrep -x Burnrate >/dev/null; then
  echo "==> quitting running Burnrate"
  osascript -e 'tell application "Burnrate" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Burnrate 2>/dev/null || true
fi

echo "==> building and installing"
make mac mac-install install

appex="$APP_DIR/Burnrate.app/Contents/PlugIns/BurnrateWidget.appex"
# only the real install location is registered, never a temp copy
if [[ "$APP_DIR" == "$HOME/Applications" ]]; then
  pluginkit -a "$appex" || echo "warning: could not register the widget with pluginkit" >&2
fi

if [[ "${BURNRATE_NO_OPEN:-}" != "1" ]]; then
  open "$APP_DIR/Burnrate.app" || true
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "warning: $PREFIX is not on your PATH; add: export PATH=\"$PREFIX:\$PATH\"" >&2 ;;
esac

cat <<NEXT

Installed $APP_DIR/Burnrate.app and $PREFIX/burnratectl.
Burnrate runs in the menu bar; start it later from Applications, Spotlight or: open -a Burnrate
  - Claude Code and Codex need only their CLI login (claude, codex login).
  - OpenRouter key and Replicate cookie: Settings > Providers (Cmd+,).
  - Widget: right-click the desktop > Edit Widgets > Burnrate.
Update: run this installer again. Uninstall: $src/scripts/uninstall.sh [--purge]
NEXT
