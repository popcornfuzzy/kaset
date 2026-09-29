#!/usr/bin/env bash
#
# test-update-flow.sh - Proves an in-app update actually installs on this machine.
#
# Usage:
#   Scripts/test-update-flow.sh [--keep-work-dir]
#
# Why this exists: Sparkle downloads an update inside the app but installs it from
# outside the app's sandbox, using helper tools that register Mach services named
# after the host bundle identifier. A sandboxed app that is not allowed to look
# those services up downloads the update and then fails to install it. No unit
# test can see that, so the only honest test is a real update against a real feed.
#
# Everything below happens against http://localhost and a throwaway bundle
# identifier, so it never touches the copy of Kaset you actually use:
#
#   1. Builds an old Kaset (KASET_E2E_FROM_*) and a new one (KASET_E2E_TO_*).
#   2. Enables automatic downloads in both builds - the one test-only override -
#      so the check, the download and the install need no clicks at all.
#   3. Packages the new build as a DMG, signs it with Sparkle's EdDSA key, and
#      serves that DMG plus the generated appcast over http://localhost.
#   4. Launches the old build and waits for it to replace itself, then reads the
#      version off disk.
#
# Exit status is 0 only if the app on disk reaches the new build number. On
# failure, the Sparkle log lines explaining the rejection are printed.
#
# Environment overrides: KASET_E2E_FROM_VERSION, KASET_E2E_FROM_BUILD,
# KASET_E2E_TO_VERSION, KASET_E2E_TO_BUILD, KASET_E2E_BUNDLE_ID, KASET_E2E_PORT,
# KASET_E2E_TIMEOUT. The Sparkle private key comes from Scripts/.env,
# releases/.env, $SPARKLE_PRIVATE_KEY, or the login keychain.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# --- Configuration ----------------------------------------------------------

WORK="$ROOT/.build/update-e2e"
FROM_VERSION="${KASET_E2E_FROM_VERSION:-0.9.0}"
FROM_BUILD="${KASET_E2E_FROM_BUILD:-9000}"
TO_VERSION="${KASET_E2E_TO_VERSION:-0.9.1}"
TO_BUILD="${KASET_E2E_TO_BUILD:-9001}"
# A throwaway identifier keeps this test's preferences, sandbox container and
# Sparkle state away from the identifier you actually run.
BUNDLE_ID="${KASET_E2E_BUNDLE_ID:-com.popcornfuzzy.Kaset.updatetest}"
PORT="${KASET_E2E_PORT:-8931}"
INSTALL_TIMEOUT="${KASET_E2E_TIMEOUT:-150}"

FEED_DIR="$WORK/feed"
FEED_URL="http://localhost:$PORT/appcast.xml"
FROM_APP="$WORK/from/Kaset.app"
TO_APP="$WORK/to/Kaset.app"
ENTITLEMENTS="$WORK/Kaset.entitlements"
SPARKLE_LOG="$WORK/sparkle.log"
SERVER_PID=""
LOG_PID=""
ORIGINAL_VERSION_ENV=""

KEEP_WORK_DIR=0
for arg in "$@"; do
  case "$arg" in
    --keep-work-dir) KEEP_WORK_DIR=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}Warning:${NC} $1"; }
fail() { echo -e "${RED}Error:${NC} $1" >&2; }

# --- Local key material -----------------------------------------------------
#
# Loaded the same way the release scripts do, so the test signs with the same key
# the packaged app declares in SUPublicEDKey. An exported key still wins over the
# .env files.
CALLER_SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
for env_file in "$ROOT/Scripts/.env" "$ROOT/releases/.env"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$env_file"
    set +a
  fi
done
if [[ -n "$CALLER_SPARKLE_PRIVATE_KEY" ]]; then
  SPARKLE_PRIVATE_KEY="$CALLER_SPARKLE_PRIVATE_KEY"
fi

# --- Cleanup ----------------------------------------------------------------

cleanup() {
  local status=$?
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
  fi
  # Only the test copy is stopped; a Kaset you launched yourself is left alone.
  pkill -f "$FROM_APP/Contents/MacOS/Kaset" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "$ORIGINAL_VERSION_ENV" && -f "$ORIGINAL_VERSION_ENV" ]]; then
    cp "$ORIGINAL_VERSION_ENV" "$ROOT/version.env"
  fi
  if [[ "$KEEP_WORK_DIR" -eq 0 && "$status" -eq 0 ]]; then
    rm -rf "$WORK"
  fi
  return "$status"
}
trap cleanup EXIT

# --- Preconditions ----------------------------------------------------------

step "Checking prerequisites"

for tool in python3 curl codesign; do
  command -v "$tool" >/dev/null 2>&1 || { fail "$tool is required."; exit 1; }
done

GENERATE=$(Scripts/generate-appcast.sh --check) || exit 1
SPARKLE_BIN=$(dirname "$GENERATE")
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  fail "sign_update not found next to generate_appcast ($SPARKLE_BIN)."
  exit 1
fi
echo "  Using $GENERATE"

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  warn "SPARKLE_PRIVATE_KEY is not set; generate_appcast will fall back to the login keychain."
  warn "If the keychain holds a different key, the feed will be generated unsigned and this test will fail."
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Port $PORT is already in use; pass KASET_E2E_PORT=<port>."
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$FEED_DIR" "$WORK/from" "$WORK/to"

# build-app.sh reads version.env rather than the environment, so the two versions
# have to be written there. The user's file is restored by the EXIT trap.
ORIGINAL_VERSION_ENV="$WORK/version.env.orig"
cp "$ROOT/version.env" "$ORIGINAL_VERSION_ENV"

# --- Build the two apps -----------------------------------------------------

build_app() {
  local version="$1" build="$2" destination="$3"

  printf 'MARKETING_VERSION=%s\nBUILD_NUMBER=%s\n' "$version" "$build" > "$ROOT/version.env"

  # A feed URL on loopback keeps the whole test on this machine. Ad-hoc signing
  # matches what the release workflow publishes.
  KASET_SIGNING=adhoc \
  KASET_BUNDLE_ID="$BUNDLE_ID" \
  KASET_SU_FEED_URL="$FEED_URL" \
    Scripts/build-app.sh release > "$WORK/build-$build.log" 2>&1 \
    || { fail "Build for $version ($build) failed; see $WORK/build-$build.log"; tail -30 "$WORK/build-$build.log" >&2; exit 1; }

  rm -rf "$destination"
  mkdir -p "$(dirname "$destination")"
  cp -R "$ROOT/.build/app/Kaset.app" "$destination"
  echo "  Built Kaset $version ($build)"
}

# The only test-only overrides: automatic downloads turn the update into a
# headless one, a 1 second check interval skips Sparkle's day-long scheduler, and
# the ATS exception lets the app fetch a loopback feed over plain http.
patch_for_test() {
  local app="$1"
  local plist="$app/Contents/Info.plist"

  /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Set :SUScheduledCheckInterval 1" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:localhost dict" "$plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:localhost:NSExceptionAllowsInsecureHTTPLoads bool true" "$plist" >/dev/null

  # Editing Info.plist breaks the bundle seal, so the app has to be re-signed with
  # exactly the entitlements build-app.sh signs with - the entitlements are half of
  # what this test is checking.
  Scripts/generate-entitlements.sh "$BUNDLE_ID" "$ENTITLEMENTS"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$app" >/dev/null 2>&1 \
    || { fail "Could not re-sign $app after patching its Info.plist."; exit 1; }
}

step "Building Kaset $FROM_VERSION ($FROM_BUILD) and $TO_VERSION ($TO_BUILD)"
build_app "$FROM_VERSION" "$FROM_BUILD" "$FROM_APP"
build_app "$TO_VERSION" "$TO_BUILD" "$TO_APP"
patch_for_test "$FROM_APP"
patch_for_test "$TO_APP"

# --- Package the new build and generate the feed ----------------------------

step "Packaging Kaset $TO_VERSION as a DMG"
Scripts/create-dmg.sh "$FEED_DIR/kaset-$TO_VERSION.dmg" "$TO_APP"

step "Generating and signing the appcast"
GENERATE_ARGS=(
  --maximum-versions 0
  --download-url-prefix "http://localhost:$PORT/"
  "$FEED_DIR"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE" --ed-key-file - "${GENERATE_ARGS[@]}"
else
  "$GENERATE" "${GENERATE_ARGS[@]}"
fi

APPCAST="$FEED_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || { fail "generate_appcast produced no appcast."; exit 1; }
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
  fail "The generated appcast has no sparkle:edSignature."
  echo "  generate_appcast only signs when the private key matches the SUPublicEDKey" >&2
  echo "  baked into the app, so the update would be rejected before installation." >&2
  exit 1
fi
echo "  Feed advertises $(grep -c '<item>' "$APPCAST") item(s)"

# --- Serve the feed ---------------------------------------------------------

step "Serving the feed on http://localhost:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_DIR" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS "$FEED_URL" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$FEED_URL" >/dev/null 2>&1 || { fail "Feed server did not come up on port $PORT."; exit 1; }
echo "  $FEED_URL is reachable"

# --- Run the update ---------------------------------------------------------

step "Launching Kaset $FROM_VERSION and waiting for it to update itself"

# A fresh defaults domain means Sparkle has no record of a recent check and runs
# one immediately.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

log stream --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle"' > "$SPARKLE_LOG" 2>&1 &
LOG_PID=$!
sleep 1

open -g "$FROM_APP"

INSTALLED_BUILD=""
deadline=$((SECONDS + INSTALL_TIMEOUT))
while [[ "$SECONDS" -lt "$deadline" ]]; do
  INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$FROM_APP/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ "$INSTALLED_BUILD" == "$TO_BUILD" ]]; then
    break
  fi
  sleep 2
done

kill "$LOG_PID" 2>/dev/null || true
LOG_PID=""

# --- Verdict ----------------------------------------------------------------

INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$FROM_APP/Contents/Info.plist" 2>/dev/null || echo "?")
INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$FROM_APP/Contents/Info.plist" 2>/dev/null || echo "?")

if [[ "$INSTALLED_BUILD" == "$TO_BUILD" ]]; then
  echo -e "\n${GREEN}PASS${NC} - Kaset updated itself from $FROM_VERSION ($FROM_BUILD) to $INSTALLED_VERSION ($INSTALLED_BUILD)"
  exit 0
fi

fail "Kaset is still $INSTALLED_VERSION ($INSTALLED_BUILD); expected $TO_VERSION ($TO_BUILD)."
echo "" >&2

echo "Sparkle said:" >&2
SPARKLE_ERRORS=""
if [[ -s "$SPARKLE_LOG" ]]; then
  SPARKLE_ERRORS=$(grep -iE "error|fail|reject|invalid|mismatch|denied|not signed" "$SPARKLE_LOG" | tail -20 || true)
  if [[ -z "$SPARKLE_ERRORS" ]]; then
    SPARKLE_ERRORS=$(tail -20 "$SPARKLE_LOG")
  fi
fi

# `log stream` attaches a moment after it starts, and a failed check can finish
# before that, so fall back to asking the unified log what already happened.
if [[ -z "$SPARKLE_ERRORS" ]]; then
  SPARKLE_ERRORS=$(log show --last 10m --style compact --info --debug \
    --predicate 'subsystem == "org.sparkle-project.Sparkle"' 2>/dev/null | tail -20 || true)
fi

if [[ -n "$SPARKLE_ERRORS" ]]; then
  echo "$SPARKLE_ERRORS" >&2
else
  echo "  (Sparkle logged nothing; the updater may never have started a check)" >&2
fi

echo "" >&2
echo "Captured log: $SPARKLE_LOG" >&2
exit 1
