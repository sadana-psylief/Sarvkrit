#!/usr/bin/env bash
# Cuts a GitHub release from a commit that is already on main.
#
#   ./scripts/release.sh 1.1.0
#   ./scripts/release.sh 1.1.0 --allow-unnotarized
#
# This no longer bumps the version or commits anything, and that is not tidying for its own sake:
# `main` is guarded by a repository ruleset ("main: PR required", with no bypass actors), so
# `git push origin main` is rejected for everyone including the owner. A release that built,
# notarized, and *then* failed to push would be the worst possible ordering. So the version bump,
# the notes and the artwork all land through a pull request first, and by the time this runs there
# is nothing left to write — only a tag to push, which the rulesets do not cover.
set -euo pipefail

VERSION=""
ALLOW_UNNOTARIZED=0
for arg in "$@"; do
  case "$arg" in
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    -*) echo "error: unknown option '$arg'" >&2; exit 1 ;;
    *) VERSION="$arg" ;;
  esac
done
[[ -n "$VERSION" ]] || { echo "usage: release.sh <version> [--allow-unnotarized]" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "error: '$VERSION' is not a version" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
TAG="v$VERSION"
DMG="dist/Sarvkrit.dmg"
NOTES_SOURCE="docs/releases/$VERSION.md"

## Everything checkable, before anything that costs time or leaves a trace.
command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }

## HEAD must *be* origin/main, not merely be called main. Releases are cut from a worktree, where
## the branch is named for the release; and the local `main` ref in a long-lived checkout is
## routinely dozens of commits stale, which a branch-name check accepts without complaint.
git fetch origin --quiet
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is dirty; commit or stash first" >&2; exit 1; }
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "error: HEAD is not origin/main. Land the release-prep pull request first, then" >&2
  echo "       git fetch origin && git reset --hard origin/main" >&2
  exit 1
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: tag $TAG already exists" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "error: release $TAG already exists" >&2; exit 1; }

## The bump is a precondition now rather than something this performs. Checking it here is what
## keeps the tag and the app's own CFBundleShortVersionString from ever disagreeing.
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || {
  echo "error: project.yml is not at $VERSION. Bump MARKETING_VERSION (and" >&2
  echo "       CURRENT_PROJECT_VERSION) through a pull request first — main takes no direct pushes." >&2
  exit 1; }

## The notes are a committed file, which is what lets them carry pictures: each one is referenced
## at raw/<tag>/docs/images/…, so it resolves only if it is in the commit being tagged. An
## untracked image is a 404 on a release page that is already public, and nothing further down
## would notice — so every path the notes reference is checked against the index now.
[[ -f "$NOTES_SOURCE" ]] || { echo "error: no release notes at $NOTES_SOURCE" >&2; exit 1; }
missing=0
while read -r asset; do
  [[ -n "$asset" ]] || continue
  git ls-files --error-unmatch "$asset" >/dev/null 2>&1 || {
    echo "error: the notes reference '$asset', which is not tracked in git" >&2; missing=1; }
done < <(grep -oE "raw/$TAG/[^)\"' ]+" "$NOTES_SOURCE" | sed "s|^raw/$TAG/||" | sort -u)
[[ $missing -eq 0 ]] || exit 1

if [[ $ALLOW_UNNOTARIZED -eq 1 ]]; then
  ## Deliberately opt-in, and deliberately loud. The default path still refuses to publish
  ## anything Gatekeeper would block; this is the escape hatch for the state the project is
  ## actually in — signed with an Apple Development certificate, because notarization needs a paid
  ## Apple Developer account. See "Notarizing, once there is a paid account" in README.md.
  ##
  ## And the notes have to say so. A DMG that sends people into System Settings while its notes
  ## claim it opens on first launch is worse than one that explains itself.
  grep -qi "Open Anyway" "$NOTES_SOURCE" || {
    echo "error: --allow-unnotarized, but $NOTES_SOURCE never mentions Open Anyway." >&2
    echo "       An un-notarized build is stopped on first launch; the notes have to say how" >&2
    echo "       to get past it." >&2
    exit 1; }
  echo "Releasing Sarvkrit $VERSION — NOT NOTARIZED"
  echo "  Downloaders are stopped by Gatekeeper on first launch and have to use"
  echo "  System Settings → Privacy & Security → Open Anyway. $NOTES_SOURCE says so."
else
  security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
    echo "error: no \"Developer ID Application\" certificate — see scripts/notarize.sh." >&2
    echo "       To ship signed-but-not-notarized, as 1.0 did:" >&2
    echo "         ./scripts/release.sh $VERSION --allow-unnotarized" >&2
    exit 1; }
  echo "Releasing Sarvkrit $VERSION"
fi

## The styled DMG is not optional for a release. build-dmg.sh's fallback produces an image with no
## background and no icon positions, and it takes that path silently.
export REQUIRE_STYLED_DMG=1
make build
make dmg
if [[ $ALLOW_UNNOTARIZED -eq 0 ]]; then
  ./scripts/notarize.sh "$DMG"   # verifies stapling and `spctl` itself, and exits non-zero otherwise
fi

## The hash is taken here, after everything that rewrites the file — stapling rewrites it, and a
## hash taken any earlier would be published beside a DMG that no longer matches it.
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
NOTES="$(mktemp -t sarvkrit-release)"
sed "s/@SHA@/$SHA/g" "$NOTES_SOURCE" > "$NOTES"
! grep -q "@SHA@" "$NOTES" || { echo "error: a @SHA@ placeholder survived substitution" >&2; exit 1; }

## Only the tag. The commit it points at is already on main, put there by the release-prep PR.
git tag -a "$TAG" -m "Sarvkrit $VERSION

Built from $(git rev-parse --short HEAD)."
git push origin "$TAG"

gh release create "$TAG" "$DMG" --title "Sarvkrit $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

## sarvkrit.com/download and the GitHub "latest" link both resolve through
## releases/latest/download/Sarvkrit.dmg, so they pick this up with no change on the site side.
echo
echo "Released $TAG. Verify the download route now points at it:"
echo "  curl -sIL -o /dev/null -w '%{url_effective}\\n' https://sarvkrit.com/download"
