#!/usr/bin/env bash
# Removes the Burnrate app and burnratectl. Keeps ~/.config/burnrate and the
# Application Support data and the Keychain keys unless --purge is given.
# Env: PREFIX (default ~/.local/bin), APP_DIR (default ~/Applications).
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
while [[ "$PREFIX" != "/" && "$PREFIX" == */ ]]; do PREFIX="${PREFIX%/}"; done
while [[ "$APP_DIR" != "/" && "$APP_DIR" == */ ]]; do APP_DIR="${APP_DIR%/}"; done
purge=0
for a in "$@"; do
  case "$a" in
    --purge) purge=1 ;;
    -h | --help) echo "usage: uninstall.sh [--purge]"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if pgrep -x Burnrate >/dev/null; then
  osascript -e 'tell application "Burnrate" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Burnrate 2>/dev/null || true
fi

appex="$APP_DIR/Burnrate.app/Contents/PlugIns/BurnrateWidget.appex"
if [[ "$APP_DIR" == "$HOME/Applications" && -d "$appex" ]]; then
  pluginkit -r "$appex" 2>/dev/null || true
fi

rm -rf "$APP_DIR/Burnrate.app"
rm -f "$PREFIX/burnratectl"
echo "removed $APP_DIR/Burnrate.app and $PREFIX/burnratectl"

if (( purge )); then
  rm -rf "$HOME/.config/burnrate" "$HOME/Library/Application Support/burnrate"
  rm -f "$HOME/Library/Preferences/local.burnrate.plist"
  # API keys from Settings: one Keychain item per key, service "burnrate"
  while /usr/bin/security delete-generic-password -s burnrate >/dev/null 2>&1; do :; done
  echo "removed ~/.config/burnrate, ~/Library/Application Support/burnrate, the app preferences and the Keychain keys"
else
  echo "kept ~/.config/burnrate, Application Support data and the Keychain keys (use --purge to delete)"
fi
