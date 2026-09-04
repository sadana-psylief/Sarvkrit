#!/usr/bin/env bash
# Re-signs with Developer ID, notarizes, staples, and verifies.
#
# This CANNOT run with only an "Apple Development" certificate — notarization requires a
# paid Apple Developer account and a "Developer ID Application" cert. Until then the DMG
# still installs fine locally; other users have to go through System Settings → Privacy &
# Security → Open Anyway once. See "Notarizing, once there is a paid account" in README.md.
set -euo pipefail

DMG_PATH="${1:?usage: notarize.sh <path-to-.dmg>}"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-SarvkritNotary}"

# Anchored to the script rather than the caller's cwd: the entitlements path and build-dmg.sh
# below are repo-relative, and `make notarize` is not the only way this gets run.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/Build/Products/Release/Sarvkrit.app"

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)"

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found in the keychain.

Notarization needs a paid Apple Developer account. Once you have one:
  1. Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application
  2. Put the certificate's Team ID in project.yml's DEVELOPMENT_TEAM. It is NOT 77A36893HP:
     that is the free personal team, and a paid membership is a different team entirely.
  3. Store an app-specific password for notarytool:
       xcrun notarytool store-credentials SarvkritNotary \
         --apple-id <you@example.com> --team-id <that same team ID> --password <app-specific-password>
  4. Re-run: make notarize

Nothing has been signed or submitted.
MSG
  exit 1
fi

[[ -d "$APP_PATH" ]] || { echo "error: no release build at $APP_PATH — run 'make build' first" >&2; exit 1; }

## Resolved only now, and only after the two checks above have had their say. `make notarize` has
## no prerequisite on `make dmg`, so dist/ often does not exist yet — resolving it any earlier made
## a missing directory pre-empt the "no Developer ID cert" message that is the real answer.
mkdir -p "$(dirname "$DMG_PATH")"
DIST_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"

## `notarytool submit --wait` has been known to exit 0 on a rejected submission, so the exit code
## alone is not the answer: require the words "status: Accepted" in its output. On anything else,
## print the server-side log, which is the only place that says *why* Apple refused — a rejection
## with no log is the thing that turns this into an afternoon.
submit() {
  local what="$1" log rc=0 id
  log="$(mktemp -t sarvkrit-notarize)"
  echo "Submitting $(basename "$what") to Apple…"
  xcrun notarytool submit "$what" --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1 | tee "$log" || rc=$?
  id="$(sed -nE 's/^ *id: ([0-9a-fA-F-]{36}).*/\1/p' "$log" | head -1)"
  if [[ $rc -ne 0 ]] || ! grep -q "status: Accepted" "$log"; then
    echo >&2
    echo "error: notarization of $(basename "$what") was not accepted." >&2
    if [[ -n "$id" ]]; then
      echo "--- notarytool log $id ---" >&2
      xcrun notarytool log "$id" --keychain-profile "$KEYCHAIN_PROFILE" >&2 || true
    else
      echo "(no submission id in the output, so no log to fetch)" >&2
    fi
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

echo "Signing with: $IDENTITY"
# Sign nested content first, then the bundle. --deep is deprecated and signs things it
# shouldn't; an explicit inside-out pass is the supported route.
#
# Two passes, because these are different kinds of thing: a .dylib is a file, a .framework is a
# *directory*. One `-type f` covering both silently matched no framework at all.
find "$APP_PATH/Contents" -type f -name "*.dylib" -print0 \
  | xargs -0 -r codesign --force --options runtime --timestamp --sign "$IDENTITY"
find "$APP_PATH/Contents" -type d -name "*.framework" -print0 \
  | xargs -0 -r codesign --force --options runtime --timestamp --sign "$IDENTITY"
codesign --force --options runtime --timestamp \
  --entitlements "$REPO_ROOT/Sources/Sarvkrit/Resources/Sarvkrit.entitlements" \
  --sign "$IDENTITY" "$APP_PATH"

## The app is notarized and stapled *before* the DMG is built, so the ticket travels inside the
## bundle. Stapling only the DMG leaves the copy someone drags to /Applications with no ticket of
## its own, which Gatekeeper then has to fetch over the network — and cannot, on a Mac that is
## offline or behind a filter. Two submissions, one build.
ZIP_PATH="$DIST_DIR/Sarvkrit-notarize.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
submit "$ZIP_PATH"
rm -f "$ZIP_PATH"
xcrun stapler staple "$APP_PATH"

"$REPO_ROOT/scripts/build-dmg.sh" "$APP_PATH" "$DIST_DIR"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
submit "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"

## Verify rather than assume. Every step above can succeed and still leave something a downloader
## would be blocked by, and this machine is the last place that would notice — a locally built app
## carries no quarantine attribute, so it opens fine either way.
echo
echo "Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
xcrun stapler validate "$DMG_PATH"

assessment="$(spctl -a -vv "$APP_PATH" 2>&1)"
echo "$assessment"
if ! grep -q "source=Notarized Developer ID" <<<"$assessment"; then
  echo "error: Gatekeeper does not see this as notarized — do not ship it." >&2
  exit 1
fi

echo
echo "Notarized, stapled and verified: $DMG_PATH"
