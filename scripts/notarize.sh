#!/usr/bin/env bash
# Re-signs with Developer ID, notarizes, and staples.
#
# This CANNOT run with only an "Apple Development" certificate — notarization requires a
# paid Apple Developer account and a "Developer ID Application" cert. Until then the DMG
# still installs fine locally; other users have to right-click → Open past Gatekeeper once.
set -euo pipefail

DMG_PATH="${1:?usage: notarize.sh <path-to-.dmg>}"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-SarvkritNotary}"

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)"

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found in the keychain.

Notarization needs a paid Apple Developer account. Once you have one:
  1. Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application
  2. Store an app-specific password for notarytool:
       xcrun notarytool store-credentials SarvkritNotary \
         --apple-id <you@example.com> --team-id 77A36893HP --password <app-specific-password>
  3. Re-run: make notarize

Nothing has been signed or submitted.
MSG
  exit 1
fi

APP_IN_DMG="$(dirname "$DMG_PATH")/../build/Build/Products/Release/Sarvkrit.app"
echo "Signing with: $IDENTITY"
# Sign nested content first, then the bundle. --deep is deprecated and signs things it
# shouldn't; an explicit inside-out pass is the supported route.
find "$APP_IN_DMG/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 \
  | xargs -0 -r codesign --force --options runtime --timestamp --sign "$IDENTITY"
codesign --force --options runtime --timestamp \
  --entitlements Sources/Sarvkrit/Resources/Sarvkrit.entitlements \
  --sign "$IDENTITY" "$APP_IN_DMG"

./scripts/build-dmg.sh "$APP_IN_DMG" "$(dirname "$DMG_PATH")"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"

echo "Submitting to Apple…"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
echo "Notarized and stapled: $DMG_PATH"
