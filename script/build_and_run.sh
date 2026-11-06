#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
cd "$ROOT_DIR/app"
swift build -c release --product LenovoSplit
BUILD_DIR="$(swift build -c release --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/Lenovo Split.next.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$ROOT_DIR/NOTICE.md" "$APP_BUNDLE/Contents/Resources/NOTICE.md"
cp "$BUILD_DIR/LenovoSplit" "$APP_BUNDLE/Contents/MacOS/LenovoSplit"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LenovoSplit</string>
<key>CFBundleIdentifier</key><string>local.lenovosplit</string>
<key>CFBundleName</key><string>Lenovo Split</string>
<key>CFBundleDisplayName</key><string>Lenovo Split</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Adapted from WD19 Split, MIT license.</string>
</dict></plist>
PLIST
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE"
case "$MODE" in
--build-only) exit 0 ;;
run) pkill -x LenovoSplit >/dev/null 2>&1 || true; open -n "$APP_BUNDLE" --args --background ;;
--verify) pkill -x LenovoSplit >/dev/null 2>&1 || true; open -n "$APP_BUNDLE" --args --background; sleep 1; pgrep -x LenovoSplit >/dev/null ;;
--logs|--telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "LenovoSplit"' ;;
--debug) lldb -- "$APP_BUNDLE/Contents/MacOS/LenovoSplit" ;;
*) echo 'usage: build_and_run.sh [--build-only|--verify|--logs|--telemetry|--debug]' >&2; exit 2 ;;
esac
