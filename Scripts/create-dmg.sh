#!/usr/bin/env bash
#
# create-dmg.sh - Packages a built Kaset.app into a distributable DMG.
#
# Usage:
#   Scripts/create-dmg.sh <output.dmg> [path/to/Kaset.app]
#
# Defaults to .build/app/Kaset.app when no app path is given.
#
# The styled layout (create-dmg) is preferred because it gives users the
# drag-to-Applications window. Its layout step drives Finder through AppleScript,
# which is not dependable on a headless CI runner, so a failure there falls back
# to a plain hdiutil image rather than failing the release. Either way the DMG
# this script leaves behind is a valid, mountable image containing Kaset.app.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUTPUT="${1:-}"
APP_PATH="${2:-.build/app/Kaset.app}"
VOLUME_NAME="Kaset"

if [[ -z "$OUTPUT" ]]; then
  echo "Usage: $0 <output.dmg> [path/to/Kaset.app]" >&2
  exit 64
fi

case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

# Remove stale output so a failed attempt can never be mistaken for success.
rm -f "$OUTPUT"

# create-dmg writes the image next to its destination argument, so run it from a
# private directory and move the finished image into place.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/kaset-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

styled_dmg() {
  command -v create-dmg >/dev/null 2>&1 || return 1

  local staged="$STAGING/kaset.dmg"
  echo "  → Building styled DMG with create-dmg..."

  # create-dmg can exit non-zero after leaving a partial image behind, so the
  # caller checks that the image exists and mounts before trusting the exit code.
  create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "Kaset.app" 180 190 \
    --app-drop-link 480 190 \
    --hide-extension "Kaset.app" \
    --no-internet-enable \
    "$staged" \
    "$APP_PATH" || return 1

  [[ -f "$staged" ]] || return 1
  mv "$staged" "$OUTPUT"
}

plain_dmg() {
  echo "  → Building plain DMG with hdiutil..."
  local contents="$STAGING/contents"
  mkdir -p "$contents"
  cp -R "$APP_PATH" "$contents/"
  ln -s /Applications "$contents/Applications"

  hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$contents" \
    -ov -format UDZO \
    -quiet \
    "$OUTPUT"
}

# Accepts the image only if it mounts, so a partial file from a failed create-dmg
# run is never published.
verify_dmg() {
  local mount_point
  mount_point=$(mktemp -d "${TMPDIR:-/tmp}/kaset-dmg-mount.XXXXXX")
  if ! hdiutil attach "$1" -nobrowse -readonly -mountpoint "$mount_point" -quiet >/dev/null 2>&1; then
    rmdir "$mount_point" 2>/dev/null || true
    return 1
  fi
  local ok=0
  [[ -d "$mount_point/Kaset.app" ]] || ok=1
  hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
  rmdir "$mount_point" 2>/dev/null || true
  return "$ok"
}

if styled_dmg; then
  echo "  → create-dmg succeeded"
else
  echo "  → create-dmg unavailable or failed; falling back to hdiutil"
  # A failed create-dmg run can leave its volume mounted; its name is ours, so
  # detaching it is safe and stops the next attempt from tripping over it.
  hdiutil detach "/Volumes/$VOLUME_NAME" -quiet >/dev/null 2>&1 || true
  rm -f "$OUTPUT"
  plain_dmg
fi

if ! verify_dmg "$OUTPUT"; then
  echo "Error: $OUTPUT is not a mountable image containing Kaset.app" >&2
  exit 1
fi

echo "  → DMG ready: $OUTPUT ($(stat -f%z "$OUTPUT") bytes)"
