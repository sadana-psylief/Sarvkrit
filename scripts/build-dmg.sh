#!/usr/bin/env bash
# Packages Sarvkrit.app into a drag-to-Applications DMG.
set -euo pipefail

APP_PATH="${1:?usage: build-dmg.sh <path-to-.app> <dist-dir>}"
DIST_DIR="${2:-dist}"
APP_NAME="$(basename "$APP_PATH" .app)"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

[[ -d "$APP_PATH" ]] || { echo "error: no app bundle at $APP_PATH" >&2; exit 1; }
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$DIST_DIR"/rw.*.dmg

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
echo "Packaging $APP_NAME $VERSION"

common=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 640 400
  --icon-size 128
  --icon "$APP_NAME.app" 160 190
  --app-drop-link 480 190
  --hide-extension "$APP_NAME.app"
  --no-internet-enable
)

# The icon layout is applied by driving Finder over AppleScript, which needs Automation
# permission for whichever terminal is running this. Without it create-dmg dies at the very
# last step, so fall back to a plain (unstyled but perfectly functional) image rather than
# failing the build.
if ! create-dmg "${common[@]}" "$DMG_PATH" "$APP_PATH"; then
  echo
  echo "note: Finder styling failed — retrying without it."
  echo "      Grant your terminal Automation access to Finder in System Settings →"
  echo "      Privacy & Security → Automation to get the laid-out drag-to-install window."
  echo
  rm -f "$DMG_PATH" "$DIST_DIR"/rw.*.dmg
  create-dmg "${common[@]}" --skip-jenkins "$DMG_PATH" "$APP_PATH"
fi

echo "Built $DMG_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/  /'
