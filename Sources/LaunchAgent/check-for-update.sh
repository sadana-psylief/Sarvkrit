#!/bin/sh
#
# Sarvkrit's only network access, and deliberately not part of the app.
#
# The app binary contains no networking code whatsoever — this launchd job is the one thing that
# talks to the internet, it is described in Contents/Library/LaunchAgents/, and you can switch it
# off in System Settings -> General -> Login Items -> Allow in the Background. All it does is ask
# GitHub what the newest release is and drop the answer in a file. It sends nothing about you:
# no account, no token, no query string, no identifier of any kind.
#
# Nothing here parses JSON. `jq` only ships from macOS 15 and this app supports 14.4, and
# /usr/bin/python3 on a stock Mac is a shim that can prompt to install Xcode. So the response is
# written to disk verbatim and Swift's JSONDecoder does the reading.
#
#   check-for-update.sh [--force]
#
set -eu

DIR="${SARVKRIT_UPDATE_DIR:-$HOME/Library/Application Support/Sarvkrit}"
URL="${SARVKRIT_UPDATE_URL:-https://api.github.com/repos/sadana-psylief/Sarvkrit/releases/latest}"
OUT="$DIR/latest-release.json"
FAIL="$DIR/update-check-failed"

## Two clocks on purpose. A good answer is worth 20 hours, but a *failure* is only worth one:
## otherwise a laptop that happened to be shut when the job fired would wait almost a full day
## after coming back online. launchd fires this every 6 hours; these are what make it fetch once.
MIN_AGE=72000   # 20h
FAIL_AGE=3600   # 1h

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { logger -t sarvkrit-update "$1"; }

## BSD stat, not GNU: `stat -c` does not exist here. A missing file reads as ancient so the
## callers below don't each need their own existence check.
age() {
  [ -f "$1" ] || { echo 999999999; return; }
  echo $(( $(date +%s) - $(stat -f %m "$1") ))
}

mkdir -p "$DIR"

if [ "$FORCE" -eq 0 ]; then
  [ "$(age "$OUT")"  -lt "$MIN_AGE"  ] && { log "skipped: checked recently"; exit 0; }
  [ "$(age "$FAIL")" -lt "$FAIL_AGE" ] && { log "skipped: failed recently"; exit 0; }
fi

## mktemp inside the destination directory, so the mv below is a rename within one filesystem and
## therefore atomic. The app reads this file on every menu bar open; it must never see a partial one.
TMP="$(mktemp "$DIR/.latest-release.XXXXXX")"
trap 'rm -f "$TMP"' EXIT INT TERM

## --max-filesize refuses an oversized response rather than truncating it. Truncating would leave
## invalid JSON that every later read logs a decode failure for, forever; refusing leaves the last
## good answer in place. 403/429 from the unauthenticated rate limit lands in the same failure
## path, which is right — one call a day only ever hits that behind a shared NAT.
if ! curl -fsSL \
      --max-time 20 --connect-timeout 10 --max-filesize 262144 \
      --retry 2 --retry-max-time 30 \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$TMP" "$URL"; then
  log "check failed: could not fetch the release feed"
  : > "$FAIL"          # never touch a good OUT — a stale answer beats no answer
  exit 0               # exit 0 so launchd doesn't back the job off and eventually stop it
fi

## The only validation the script does: did we get JSON at all? Enough to reject a captive
## portal's login page or a proxy interstitial, so those never replace a good answer.
if [ ! -s "$TMP" ] || [ "$(head -c 1 "$TMP")" != "{" ]; then
  log "check failed: response was not JSON"
  : > "$FAIL"
  exit 0
fi

mv -f "$TMP" "$OUT"
trap - EXIT INT TERM
rm -f "$FAIL"
log "wrote $OUT"
