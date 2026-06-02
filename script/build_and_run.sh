#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MarkShot"
BUNDLE_ID="${MARKSHOT_BUNDLE_ID:-com.deskagent.MarkShot}"
HANDOFF_ACTIVITY_TYPE="${MARKSHOT_HANDOFF_ACTIVITY_TYPE:-$BUNDLE_ID.hermesConversation}"
MIN_SYSTEM_VERSION="13.0"
SIGN_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALL_DIR="${MARKSHOT_INSTALL_DIR:-/Applications}"
if [[ ! -w "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/Applications"
fi
INSTALL_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSUserActivityTypes</key>
  <array>
    <string>$HANDOFF_ACTIVITY_TYPE</string>
  </array>
  <key>NSCameraUsageDescription</key>
  <string>MarkShot uses the camera only when you open the notch webcam preview.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MarkShot uses the microphone only when you start live voice from the Notch.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MarkShot uses speech recognition only when you turn on optional wake phrase listening in the Notch.</string>
  <key>NSRemindersUsageDescription</key>
  <string>MarkShot uses Reminders access only to show and manage your Apple Reminders from the Notch.</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - --requirements "$SIGN_REQUIREMENT" "$APP_BUNDLE" >/dev/null

open_app() {
  install_app
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
  /usr/bin/codesign --force --deep --sign - --requirements "$SIGN_REQUIREMENT" "$INSTALL_BUNDLE" >/dev/null
  "$LSREGISTER" -f "$INSTALL_BUNDLE" >/dev/null 2>&1 || true
  echo "Installed $INSTALL_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --install|install)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac
