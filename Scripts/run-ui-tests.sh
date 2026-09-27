#!/usr/bin/env bash
# Runs the UI tests against a freshly built app, in UI test (mock) mode.
#
# The UI tests drive a real build of Kaset, so four things have to be in place first. Doing them by
# hand is error-prone enough that each failure looks like a different problem (see docs/testing.md):
#
#   1. the app has to be built and installed at /Applications/Kaset.app, which is what
#      KasetUITestCase launches;
#   2. no other instance may be running — with the same bundle ID already running, the app under
#      test never gets a process ID and the test fails on launch;
#   3. the test runner has to be signed; without signing it is killed before it connects
#      ("Test crashed with signal kill before establishing connection");
#   4. UI test mode has to be switched on through a marker file, because the runner is sandboxed and
#      macOS drops the launch arguments and environment it passes to the app.
#
# Usage:
#   Scripts/run-ui-tests.sh                                  # every UI test
#   Scripts/run-ui-tests.sh KasetUITests/MyUITests           # one class
#   Scripts/run-ui-tests.sh KasetUITests/MyUITests/testFoo   # one test

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MARKER="$HOME/Library/Application Support/Kaset/UITestMode"
# Written by the app when it comes up in UI test mode; see the check in cleanup below.
SEEN="$HOME/Library/Application Support/Kaset/UITestModeSeen"
APP="/Applications/Kaset.app"
DERIVED_DATA="${UI_TEST_DERIVED_DATA:-$ROOT/build}"

# Take down any running instance; a live one blocks the app under test from launching.
pkill -f "$APP/Contents/MacOS/Kaset" 2>/dev/null || true
sleep 1

echo "🔨 Building app bundle..."
KASET_SIGNING=adhoc Scripts/build-app.sh debug

echo "📦 Installing to $APP..."
rm -rf "$APP/Contents"
cp -R .build/app/Kaset.app/Contents "$APP/Contents"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"

# UI test mode. Removed again on the way out, even if the tests fail.
mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"
rm -f "$SEEN"
cleanup() {
  rm -f "$MARKER"
  pkill -f "$APP/Contents/MacOS/Kaset" 2>/dev/null || true

  # A run that never entered UI test mode talked to the real account and the real Keychain, where
  # every rebuild triggers a system permission prompt (see docs/testing.md). Say so, because the
  # symptom otherwise looks like a test-data bug.
  if [[ ! -f "$SEEN" ]]; then
    echo "⚠️  The app never came up in UI Test mode: this run used the real account." >&2
  fi
  rm -f "$SEEN"
}
trap cleanup EXIT

ONLY_TESTING=()
if [[ $# -gt 0 ]]; then
  ONLY_TESTING=(-only-testing:"$1")
fi

# A runner bundle left behind by an interrupted run cannot be re-linked in place on macOS
# ("open() failed, errno=1 (Operation not permitted)"), so drop it before building.
rm -rf "$DERIVED_DATA/Build/Products/Debug/KasetUITests-Runner.app"

echo "🧪 Running UI tests..."
set -o pipefail
xcodebuild \
  -project KasetUITests.xcodeproj \
  -scheme KasetUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"} \
  test
