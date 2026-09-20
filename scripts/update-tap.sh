#!/usr/bin/env bash
# Points the Homebrew cask at an already-published release.
#
#   ./scripts/update-tap.sh 1.1.0
#
# Separate from release.sh, and runnable on its own, for two reasons. It hashes the DMG that
# GitHub is actually serving rather than the one in dist/, so what the cask promises is what
# users receive even if the two ever diverge. And when release.sh publishes a release but the
# tap push fails — a network blip, an expired key — the release is already live and irreversible;
# re-running this is the whole recovery, and it has to work without cutting anything again.
set -euo pipefail

VERSION="${1:?usage: update-tap.sh <version>, e.g. update-tap.sh 1.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "error: '$VERSION' is not a version" >&2; exit 1; }

TAG="v$VERSION"
TAP_REMOTE="git@github.com-2:sadana-psylief/homebrew-tap.git"
CASK="Casks/sarvkrit.rb"

## Everything checkable, before anything that costs time or leaves a trace.
command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 || {
  echo "error: no release $TAG — this bumps the cask to a release that already exists" >&2; exit 1; }

TMP="$(mktemp -d -t sarvkrit-tap)"
trap 'rm -rf "$TMP"' EXIT INT TERM

## The published asset, not dist/Sarvkrit.dmg. Notarization stapling rewrites the file, and a
## hash taken from a local build is only ever a claim about a local build.
gh release download "$TAG" --pattern Sarvkrit.dmg --dir "$TMP"
SHA="$(shasum -a 256 "$TMP/Sarvkrit.dmg" | awk '{print $1}')"
echo "$TAG  sha256 $SHA"

## A fresh clone rather than $(brew --repository)/Library/Taps/sadana-psylief/homebrew-tap. That
## checkout belongs to whoever is running this: its origin is the HTTPS URL brew taps with, it may
## be mid-rebase, and `brew update` will happily reset it under us.
git clone --quiet --depth 1 "$TAP_REMOTE" "$TMP/tap"
cd "$TMP/tap"
[[ -f "$CASK" ]] || { echo "error: $CASK is missing from the tap" >&2; exit 1; }

/usr/bin/sed -i '' \
  -e "s/^\( *version \).*/\1\"$VERSION\"/" \
  -e "s/^\( *sha256 \).*/\1\"$SHA\"/" \
  "$CASK"
## Confirm the rewrite landed rather than trusting sed's exit status, which is 0 whether or not
## the pattern matched. Same reason release.sh re-greps project.yml after bumping it.
grep -q "^  version \"$VERSION\"$" "$CASK" || { echo "error: version rewrite did not apply" >&2; exit 1; }
grep -q "^  sha256 \"$SHA\"$" "$CASK"      || { echo "error: sha256 rewrite did not apply" >&2; exit 1; }

if [[ -z "$(git status --porcelain)" ]]; then
  echo "Cask is already at $VERSION with this hash — nothing to push."
  exit 0
fi

git add "$CASK"
git commit --quiet -m "Sarvkrit $VERSION"
git push --quiet origin HEAD

echo
echo "Tap updated. Verify with:"
echo "  brew update && brew upgrade --cask sarvkrit"
echo "  brew install --cask sadana-psylief/tap/sarvkrit    # or --adopt over an existing copy"
