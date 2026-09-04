#!/usr/bin/env bash
# Cuts a notarized GitHub release. Notarization is the gate: the tag is not pushed and the
# release is not created unless `notarize.sh` has verified its own work first, so there is no
# path through here that publishes a DMG users would be blocked by.
#
#   ./scripts/release.sh 1.0.1
set -euo pipefail

VERSION="${1:?usage: release.sh <version>, e.g. release.sh 1.0.1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "error: '$VERSION' is not a version" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
TAG="v$VERSION"
DMG="dist/Sarvkrit.dmg"

## Fail on everything checkable before doing anything that costs time or leaves a trace. A
## half-finished release — tag pushed, notarization refused — is worse than no release.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || { echo "error: on '$BRANCH' — releases are cut from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is dirty; commit or stash first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: tag $TAG already exists" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "error: release $TAG already exists" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
  echo "error: no \"Developer ID Application\" certificate — see scripts/notarize.sh" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }

echo "Releasing Sarvkrit $VERSION"

# MARKETING_VERSION lives in project.yml, not the generated .xcodeproj, so this is the one place
# it changes. CURRENT_PROJECT_VERSION follows it rather than counting separately: nothing here
# needs a build number independent of the version, and Apple accepts a dotted string for it just
# as happily as the "1" it holds today.
/usr/bin/sed -i '' \
  -e "s/^\( *MARKETING_VERSION: \).*/\1\"$VERSION\"/" \
  -e "s/^\( *CURRENT_PROJECT_VERSION: \).*/\1\"$VERSION\"/" \
  project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || { echo "error: version bump did not apply" >&2; exit 1; }

make build
make dmg
./scripts/notarize.sh "$DMG"   # verifies stapling and `spctl` itself, and exits non-zero otherwise

## Only past this line is the DMG known to be notarized, stapled and accepted by Gatekeeper.
## The hash is taken now, after stapling, because stapling rewrites the file — a hash taken any
## earlier would be published alongside a DMG that no longer matches it.
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
NOTES="$(mktemp -t sarvkrit-release)"
cat > "$NOTES" <<NOTES_BODY
**Sarvkrit lives in the menu bar and fixes the things macOS does differently than you'd expect.** Everything ships switched off; turn on only what you want.

## Install

1. Download \`Sarvkrit.dmg\` below and drag **Sarvkrit** to your Applications folder. Put it there rather than leaving it in Downloads — macOS keys permissions to where the app lives.
2. Open it. This build is signed with a Developer ID certificate and notarized by Apple, so it opens on first launch with no Gatekeeper detour.
3. Features that watch for keys or clicks will ask for Accessibility access when you switch them on.

## Requirements

- **macOS 14.4 or later.**
- **Universal** — Apple Silicon and Intel.

## Verifying the download

\`\`\`
shasum -a 256 Sarvkrit.dmg
$SHA
\`\`\`

Signed, notarized and stapled — \`spctl -a -vv Sarvkrit.app\` reports \`source=Notarized Developer ID\`.

## Licence

[PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) — free to use for anything including at work, source public to read and change. You may not use the code to build a competing product. Source-available, not open source.
NOTES_BODY

git add project.yml
git commit -m "Release $VERSION"
git tag -a "$TAG" -m "Sarvkrit $VERSION"
git push origin HEAD "$TAG"

gh release create "$TAG" "$DMG" --title "Sarvkrit $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

## sarvkrit.com/download and the GitHub "latest" link both resolve through
## releases/latest/download/Sarvkrit.dmg, so they pick this up with no change on the site side.
echo
echo "Released $TAG. Verify the download route now points at it:"
echo "  curl -sIL -o /dev/null -w '%{url_effective}\\n' https://sarvkrit.com/download"
