#!/usr/bin/env bash
# Packages Sarvkrit.app into a drag-to-Applications DMG.
set -euo pipefail

APP_PATH="${1:?usage: build-dmg.sh <path-to-.app> <dist-dir>}"
DIST_DIR="${2:-dist}"
APP_NAME="$(basename "$APP_PATH" .app)"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
## Anchored to the script, not the caller's cwd: notarize.sh calls this from wherever it was run,
## and the background art below is repo-relative.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -d "$APP_PATH" ]] || { echo "error: no app bundle at $APP_PATH" >&2; exit 1; }
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$DIST_DIR"/rw.*.dmg

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
echo "Packaging $APP_NAME $VERSION"

## The background art, and the two icon positions it was drawn around.
##
## `scripts/make-release-art.swift` writes the two PNGs; they are combined here rather than
## committed as a third file, so there is one source of truth for the picture. `tiffutil
## -cathidpicheck` is what carries both scales in one file — create-dmg copies the background
## verbatim into `.background/` and hands the path to Finder, which reads the 2x representation
## out of a TIFF and would otherwise draw a 700pt image at 1400pt on a Retina display.
##
## Change the window size and these three numbers move with it, along with `dmgSize`,
## `iconCentreFromTop`, `appIconX` and `dropIconX` in make-release-art.swift. Finder's icon view
## measures y from the top, which is the convention that script converts from.
ART_DIR="$REPO_ROOT/docs/images"
BACKGROUND="$DIST_DIR/dmg-background.tiff"
if [[ -f "$ART_DIR/dmg-background.png" && -f "$ART_DIR/dmg-background@2x.png" ]]; then
  tiffutil -cathidpicheck "$ART_DIR/dmg-background.png" "$ART_DIR/dmg-background@2x.png" \
    -out "$BACKGROUND" >/dev/null
else
  echo "error: no background art in $ART_DIR — run 'make preview' then" >&2
  echo "       'swift scripts/make-release-art.swift build/preview docs/images'" >&2
  exit 1
fi

common=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 700 460
  --background "$BACKGROUND"
  --icon-size 128
  --icon "$APP_NAME.app" 200 250
  --app-drop-link 500 250
  --hide-extension "$APP_NAME.app"
  --no-internet-enable
)

# The icon layout and the background are applied by driving Finder over AppleScript, which needs
# Automation permission for whichever terminal is running this. Without it create-dmg dies at the
# very last step.
#
# The fallback produces a DMG that installs perfectly well and looks like nothing at all: no
# background, no icon positions, the two icons wherever Finder feels like putting them. That is a
# reasonable trade for a local build and the wrong one for a release, so `release.sh` sets
# REQUIRE_STYLED_DMG=1 and this refuses rather than quietly shipping the plain image.
if ! create-dmg "${common[@]}" "$DMG_PATH" "$APP_PATH"; then
  echo
  echo "note: Finder styling failed."
  echo "      Grant your terminal Automation access to Finder in System Settings →"
  echo "      Privacy & Security → Automation to get the laid-out drag-to-install window."
  echo
  if [[ "${REQUIRE_STYLED_DMG:-0}" == "1" ]]; then
    echo "error: REQUIRE_STYLED_DMG=1 and the styling did not apply — not shipping a plain DMG." >&2
    rm -f "$DMG_PATH" "$DIST_DIR"/rw.*.dmg
    exit 1
  fi
  echo "      Retrying without it."
  rm -f "$DMG_PATH" "$DIST_DIR"/rw.*.dmg
  create-dmg "${common[@]}" --skip-jenkins "$DMG_PATH" "$APP_PATH"
fi

echo "Built $DMG_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/  /'
