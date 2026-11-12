#!/bin/bash
# Builds ProcXRay into ./build (always an optimized build).
#   ./build-app.sh            dev build:     build/ProcXRay Dev.app, bundle id local.procxray.dev
#   ./build-app.sh --release  installable:   build/ProcXRay.app,     bundle id local.procxray
#   ./build-app.sh --install  --release, then replaces /Applications/ProcXRay.app (quitting and relaunching it if running)
# macOS registers the privileged helper by bundle id, and whichever copy with that id launched last takes the
# registration over. Dev builds get their own id (and helper, and settings) so running one never breaks the
# installed app's helper. Uses full Xcode: the Command Line Tools
# SDK for macOS 27 lacks the SwiftUI macro plugin, so `@State` fails to compile there.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
case "${1:-}" in
  --release) BUNDLE_ID=local.procxray;     NAME=ProcXRay ;;
  --install) BUNDLE_ID=local.procxray;     NAME=ProcXRay; INSTALL=1 ;;
  "")        BUNDLE_ID=local.procxray.dev; NAME="ProcXRay Dev" ;;
  *) echo "usage: $0 [--release | --install]" >&2; exit 2 ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProcXRay"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProcXRay"
# App icon (regenerate with: swift tools/make-icon.swift Resources)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM stamps the binary with sdk == deployment target (14.0). AppKit then runs the app in
# macOS-14 compatibility mode (opaque toolbar band, thicker split divider → a 2pt "kink" where the
# sidebar meets the toolbar). Record the SDK we actually built against, keeping minos 14.0.
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VER" -replace -output "$APP/Contents/MacOS/ProcXRay" "$APP/Contents/MacOS/ProcXRay"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ProcXRay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Privileged helper: the same binary, started by launchd as root with --helper (SMAppService.daemon).
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cat > "$APP/Contents/Library/LaunchDaemons/$BUNDLE_ID.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/ProcXRay</string>
  <key>ProgramArguments</key>
  <array><string>ProcXRay</string><string>--helper</string></array>
  <key>MachServices</key>
  <dict><key>$BUNDLE_ID.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>$BUNDLE_ID</string></array>
</dict>
</plist>
PLIST

# Sign with an Apple Development identity: SMAppService won't run an ad-hoc daemon, and the helper's XPC
# listener only accepts clients signed by this team. Override with SIGN_ID=<sha1 or name>.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$SIGN_ID" ]]; then
  echo "warning: no Apple Development identity; signing ad-hoc (privileged helper will not work)" >&2
  SIGN_ID=-
fi
# --identifier: the helper derives its mach service and plist name from this (HelperConfig.bundleID).
codesign --force --options runtime --timestamp=none --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority=Apple Development' || true
echo "built $APP"

[[ $INSTALL == 1 ]] || exit 0

DEST="/Applications/$NAME.app"
EXE="$DEST/Contents/MacOS/ProcXRay"
# PIDs of the installed GUI app. The root helper (same binary, run with --helper) is left alone.
gui_pids() { ps -axo pid=,args= | awk -v exe="$EXE" '$2 == exe && !/--helper/ {print $1}'; }

PIDS="$(gui_pids)"
if [[ -n "$PIDS" ]]; then
  echo "quitting running $NAME ($(echo $PIDS))"
  kill -TERM $PIDS 2>/dev/null || true
  for _ in {1..50}; do [[ -z "$(gui_pids)" ]] && break; sleep 0.1; done
  PIDS="$(gui_pids)"
  if [[ -n "$PIDS" ]]; then kill -KILL $PIDS 2>/dev/null || true; sleep 0.2; fi
  WAS_RUNNING=1
else
  WAS_RUNNING=0
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "installed $DEST"

if [[ $WAS_RUNNING == 1 ]]; then
  open "$DEST"
  echo "relaunched $NAME"
fi
