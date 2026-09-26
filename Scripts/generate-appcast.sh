#!/usr/bin/env bash
#
# generate-appcast.sh - Regenerates appcast.xml with Sparkle's generate_appcast.
#
# Usage:
#   # Add one published release to the feed (used by the release pipeline):
#   Scripts/generate-appcast.sh --tag v0.8.0 --dmg path/to/kaset-v0.8.0.dmg
#
#   # Regenerate from a local directory of archives (manual release prep):
#   Scripts/generate-appcast.sh --releases-dir releases
#
#   # Report whether Sparkle's tools are available:
#   Scripts/generate-appcast.sh --check
#
# Options:
#   --tag <tag>            Release tag the DMG belongs to (e.g. v0.8.0)
#   --dmg <path>           DMG of the release being published
#   --releases-dir <dir>   Directory of archives to generate from instead
#   --repo <owner/name>    Repository for download URLs (default: $GITHUB_REPOSITORY)
#   --output <path>        Feed to update in place (default: ./appcast.xml)
#   --key-file <path>      Sparkle EdDSA private key file
#   --check                Exit 0 if Sparkle's tools can be found, 1 otherwise
#
# The private key is read from --key-file, else from $SPARKLE_PRIVATE_KEY (passed
# to Sparkle over stdin), else from the login keychain.
#
# History is preserved: the feed already in the repository is used as the base, so
# existing items keep their signatures and are never dropped.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# A key exported by the caller (CI, or a one-off run) has to win over the local
# .env file, whose whole purpose is to make runs work without exporting anything.
CALLER_SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"

# Load optional local environment overrides (kept out of git).
if [[ -f "$ROOT/Scripts/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/Scripts/.env"
  set +a
fi

if [[ -n "$CALLER_SPARKLE_PRIVATE_KEY" ]]; then
  SPARKLE_PRIVATE_KEY="$CALLER_SPARKLE_PRIVATE_KEY"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "$1"; }
print_error() { echo -e "${RED}Error:${NC} $1" >&2; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}Warning:${NC} $1"; }

# Sparkle ships generate_appcast/sign_update as binary artifacts of the SwiftPM
# Sparkle package, so the tools only exist once the package has been resolved or
# built. SwiftPM has moved them between layouts over time, hence the search.
find_sparkle_bin() {
  local candidates=(
    "$ROOT/.build/artifacts/sparkle/Sparkle/bin/$1"
    "$ROOT/.build/index-build/artifacts/sparkle/Sparkle/bin/$1"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  local search_roots=(
    "$ROOT/.build/artifacts"
    "$ROOT/.build/index-build"
    "$HOME/Library/Developer/Xcode/DerivedData"
  )
  for root in "${search_roots[@]}"; do
    [[ -d "$root" ]] || continue
    local found
    found=$(find "$root" -name "$1" -type f -perm -u+x 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  done

  if command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
    return 0
  fi

  return 1
}

missing_tools_message() {
  print_error "Could not find Sparkle's generate_appcast tool."
  echo "" >&2
  echo "Sparkle's command line tools ship inside the Sparkle SwiftPM artifact, so" >&2
  echo "resolve or build the package first:" >&2
  echo "" >&2
  echo "  swift package resolve    # downloads the artifact (fast)" >&2
  echo "  swift build              # fallback when resolve does not fetch it" >&2
}

# --- Argument parsing -------------------------------------------------------

TAG=""
DMG=""
RELEASES_DIR=""
REPO="${GITHUB_REPOSITORY:-popcornfuzzy/kaset}"
OUTPUT="$ROOT/appcast.xml"
KEY_FILE=""
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --releases-dir) RELEASES_DIR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) print_error "Unknown option: $1"; exit 64 ;;
    *) RELEASES_DIR="$1"; shift ;;
  esac
done

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  tool=$(find_sparkle_bin generate_appcast) || { missing_tools_message; exit 1; }
  echo "$tool"
  exit 0
fi

GENERATE=$(find_sparkle_bin generate_appcast) || { missing_tools_message; exit 1; }
print_success "Using generate_appcast: $GENERATE"

# --- Staging ----------------------------------------------------------------

if [[ -n "$DMG" ]]; then
  if [[ -z "$TAG" ]]; then
    print_error "--dmg requires --tag so the download URL can be built."
    exit 64
  fi
  if [[ ! -f "$DMG" ]]; then
    print_error "DMG not found: $DMG"
    exit 1
  fi

  VERSION="${TAG#v}"
  STAGING=$(mktemp -d "${TMPDIR:-/tmp}/kaset-appcast.XXXXXX")
  trap 'rm -rf "$STAGING"' EXIT

  # generate_appcast updates an appcast.xml found beside the archives, which is
  # how the existing feed (and its signatures) survives regeneration.
  if [[ -f "$OUTPUT" ]]; then
    cp "$OUTPUT" "$STAGING/appcast.xml"
  else
    print_warning "No existing feed at $OUTPUT; generating a fresh one."
  fi

  # The archive filename becomes the download URL, so it must match the name the
  # release actually publishes.
  cp "$DMG" "$STAGING/$(basename "$DMG")"
  ARCHIVES_DIR="$STAGING"

  DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
  RELEASE_NOTES_URL="https://github.com/$REPO/releases/tag/$TAG"
elif [[ -n "$RELEASES_DIR" ]]; then
  if [[ ! -d "$RELEASES_DIR" ]]; then
    print_error "Releases directory not found: $RELEASES_DIR"
    exit 1
  fi
  if [[ -z "$TAG" ]]; then
    print_error "--releases-dir requires --tag so the download URLs can be built."
    exit 64
  fi

  VERSION="${TAG#v}"
  ARCHIVES_DIR="$RELEASES_DIR"
  DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
  RELEASE_NOTES_URL="https://github.com/$REPO/releases/tag/$TAG"
else
  print_error "Nothing to do: pass --dmg <path> --tag <tag>, or --releases-dir <dir> --tag <tag>."
  exit 64
fi

# --- Generate ---------------------------------------------------------------

GENERATE_ARGS=(
  --maximum-versions 0
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --full-release-notes-url "$RELEASE_NOTES_URL"
  --link "https://github.com/$REPO/releases"
  "$ARCHIVES_DIR"
)

log ""
log "Generating appcast for $TAG (version $VERSION)..."
log ""

if [[ -n "$KEY_FILE" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    print_error "Key file not found: $KEY_FILE"
    exit 1
  fi
  "$GENERATE" --ed-key-file "$KEY_FILE" "${GENERATE_ARGS[@]}"
elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # Sparkle reads '-' from stdin, which keeps the key out of the process table
  # and off the filesystem.
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE" --ed-key-file - "${GENERATE_ARGS[@]}"
else
  print_warning "No SPARKLE_PRIVATE_KEY set; falling back to the login keychain."
  "$GENERATE" "${GENERATE_ARGS[@]}"
fi

GENERATED="$ARCHIVES_DIR/appcast.xml"
if [[ ! -f "$GENERATED" ]]; then
  print_error "generate_appcast did not produce an appcast."
  exit 1
fi

# --- Verify -----------------------------------------------------------------
#
# A feed that parses but advertises an unsigned or missing enclosure is worse
# than a failed run: Sparkle refuses the update and every installed copy silently
# stops updating. Every check below is a hard failure.

if command -v xmllint >/dev/null 2>&1; then
  if ! xmllint --noout "$GENERATED" 2>/dev/null; then
    print_error "Generated appcast is not valid XML."
    exit 1
  fi
fi

ITEM=$(awk -v want="$VERSION" '
  BEGIN { RS = "</item>" }
  $0 ~ ("<sparkle:shortVersionString>" want "</sparkle:shortVersionString>") { print; exit }
' "$GENERATED")

if [[ -z "$ITEM" ]]; then
  print_error "The generated feed has no item for version $VERSION."
  echo "  Sparkle only adds an item when its CFBundleVersion is newer than the" >&2
  echo "  newest item already in $OUTPUT. Check version.env/BUILD_NUMBER." >&2
  exit 1
fi

if [[ "$ITEM" != *"download/$TAG/"* ]]; then
  print_error "The item for $VERSION does not point at the $TAG release."
  exit 1
fi

SIGNATURE=$(printf '%s' "$ITEM" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
if [[ -z "$SIGNATURE" ]]; then
  print_error "The item for $VERSION has no sparkle:edSignature."
  echo "  Sparkle only signs an archive when the app inside it declares" >&2
  echo "  SUPublicEDKey matching the supplied private key." >&2
  exit 1
fi

LENGTH=$(printf '%s' "$ITEM" | sed -n 's/.*length="\([0-9]*\)".*/\1/p' | head -1)
print_success "Signed item for $VERSION ($LENGTH bytes)"

# Verify the signature against the archive we are about to publish. Sparkle
# derives the appcast signature from the key the app itself declares, so a
# mismatch here means every installed copy would reject the update.
if [[ -n "$DMG" ]]; then
  SIGN_UPDATE=$(find_sparkle_bin sign_update || true)
  KEY_AVAILABLE=0
  if [[ -n "$KEY_FILE" ]]; then
    KEY_AVAILABLE=1
  elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    KEY_AVAILABLE=2
  fi

  if [[ -z "$SIGN_UPDATE" ]]; then
    print_warning "sign_update not found; signature left unverified."
  elif [[ "$KEY_AVAILABLE" -eq 1 ]]; then
    "$SIGN_UPDATE" --ed-key-file "$KEY_FILE" --verify "$DMG" "$SIGNATURE" \
      || { print_error "The generated signature does not verify against $DMG."; exit 1; }
    print_success "Signature verified against the archive"
  elif [[ "$KEY_AVAILABLE" -eq 2 ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$DMG" "$SIGNATURE" \
      || { print_error "The generated signature does not verify against $DMG."; exit 1; }
    print_success "Signature verified against the archive"
  else
    print_warning "No key material available; signature left unverified."
  fi
fi

if [[ "$GENERATED" != "$OUTPUT" ]]; then
  cp "$GENERATED" "$OUTPUT"
fi

COUNT=$(grep -c '<item>' "$OUTPUT" || true)
print_success "Wrote $OUTPUT with $COUNT item(s)"

# --- Sync version.env -------------------------------------------------------
#
# The feed is what installed copies check for updates, but a local build stamps
# the app with version.env. Left untouched, version.env keeps advertising the
# previous release, so building locally pops a persistent "update available"
# prompt that an older local build can never satisfy. Mirror the release into it:
# the marketing version from the tag and the build number Sparkle actually
# recorded (the DMG's CFBundleVersion). A local build then compares equal to the
# published feed — never older — and stops being told to update.
VERSION_ENV="$ROOT/version.env"
if [[ -f "$VERSION_ENV" ]]; then
  APPCAST_BUILD=$(printf '%s' "$ITEM" | sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p')
  if [[ -z "$APPCAST_BUILD" ]]; then
    print_warning "Could not read sparkle:version from the generated item; leaving version.env unchanged."
  elif grep -qx "MARKETING_VERSION=$VERSION" "$VERSION_ENV" \
    && grep -qx "BUILD_NUMBER=$APPCAST_BUILD" "$VERSION_ENV"; then
    print_success "version.env already at $VERSION ($APPCAST_BUILD)"
  else
    TMP_VERSION_ENV=$(mktemp)
    MARKETING_SEEN=0
    BUILD_SEEN=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        MARKETING_VERSION=*) printf 'MARKETING_VERSION=%s\n' "$VERSION"; MARKETING_SEEN=1 ;;
        BUILD_NUMBER=*) printf 'BUILD_NUMBER=%s\n' "$APPCAST_BUILD"; BUILD_SEEN=1 ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$VERSION_ENV" > "$TMP_VERSION_ENV"
    [[ "$MARKETING_SEEN" -eq 1 ]] || printf 'MARKETING_VERSION=%s\n' "$VERSION" >> "$TMP_VERSION_ENV"
    [[ "$BUILD_SEEN" -eq 1 ]] || printf 'BUILD_NUMBER=%s\n' "$APPCAST_BUILD" >> "$TMP_VERSION_ENV"
    mv "$TMP_VERSION_ENV" "$VERSION_ENV"
    print_success "Updated version.env to $VERSION ($APPCAST_BUILD)"
  fi
fi
