#!/usr/bin/env bash
# Builds mac/dist/Burnrate.app with the desktop widget inside, ad-hoc signed (runs on
# the Mac that built it), and bin/burnratectl beside the repo. No Xcode project needed.
# BUNDLE_ID=com.you.burnrate mac/build-app.sh picks another bundle id; the widget gets $BUNDLE_ID.widget.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-local.burnrate}"
swift build -c release --package-path mac
bin="$(swift build -c release --package-path mac --show-bin-path)"

app=mac/dist/Burnrate.app
widget="$app/Contents/PlugIns/BurnrateWidget.appex"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$widget/Contents/MacOS" "$widget/Contents/Resources/Fonts"
cp "$bin/Burnrate" "$app/Contents/MacOS/Burnrate"
cp mac/Resources/Fonts/*.ttf mac/Resources/Fonts/OFL-*.txt "$app/Contents/Resources/Fonts/"
cp mac/Resources/Info.plist "$app/Contents/Info.plist"
cp mac/Resources/Burnrate.icns "$app/Contents/Resources/Burnrate.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$app/Contents/Info.plist"

cp "$bin/BurnrateWidget" "$widget/Contents/MacOS/BurnrateWidget"
cp mac/Resources/Widget-Info.plist "$widget/Contents/Info.plist"
# the Cyberpunk widget is all mono; the sandbox cannot read the app's copy
cp mac/Resources/Fonts/JetBrainsMono-*.ttf mac/Resources/Fonts/OFL-JetBrainsMono.txt "$widget/Contents/Resources/Fonts/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.widget" "$widget/Contents/Info.plist"

# inner code first, then the bundle; the widget must be sandboxed
codesign -s - -f --entitlements mac/Resources/Widget.entitlements "$widget"
codesign -s - -f "$app"
mkdir -p bin
cp "$bin/burnratectl" bin/burnratectl
echo "built $app"
