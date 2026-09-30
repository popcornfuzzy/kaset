#!/usr/bin/env bash
# Build script to create Kaset.app bundle
# Based on Kuyruk/CodexBar packaging approach

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Values the caller exported have to win over Scripts/.env: that file exists to
# make local runs work without exporting anything, not to silently override an
# explicit choice. Scripts/generate-appcast.sh applies the same rule to the
# signing key. Without this, every caller that sets KASET_BUNDLE_ID or
# KASET_SU_FEED_URL (Scripts/test-update-flow.sh, for one) quietly builds against
# the local development values instead.
KASET_SIGNING_EXPORTED="${KASET_SIGNING:-}"
KASET_BUNDLE_ID_EXPORTED="${KASET_BUNDLE_ID:-}"
KASET_SU_FEED_URL_EXPORTED="${KASET_SU_FEED_URL:-}"
APP_IDENTITY_EXPORTED="${APP_IDENTITY:-}"
ARCHES_EXPORTED="${ARCHES:-}"
SPARKLE_PUBLIC_KEY_EXPORTED="${SPARKLE_PUBLIC_KEY:-}"

# Load optional local environment overrides (kept out of git).
if [[ -f "$ROOT/Scripts/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/Scripts/.env"
  set +a
fi

if [[ -n "$KASET_SIGNING_EXPORTED" ]]; then KASET_SIGNING="$KASET_SIGNING_EXPORTED"; fi
if [[ -n "$KASET_BUNDLE_ID_EXPORTED" ]]; then KASET_BUNDLE_ID="$KASET_BUNDLE_ID_EXPORTED"; fi
if [[ -n "$KASET_SU_FEED_URL_EXPORTED" ]]; then KASET_SU_FEED_URL="$KASET_SU_FEED_URL_EXPORTED"; fi
if [[ -n "$APP_IDENTITY_EXPORTED" ]]; then APP_IDENTITY="$APP_IDENTITY_EXPORTED"; fi
if [[ -n "$ARCHES_EXPORTED" ]]; then ARCHES="$ARCHES_EXPORTED"; fi
if [[ -n "$SPARKLE_PUBLIC_KEY_EXPORTED" ]]; then SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY_EXPORTED"; fi

# Load version info
source "$ROOT/version.env"

# Configuration
CONF=${1:-release}
SIGNING_MODE=${KASET_SIGNING:-dev}
APP_NAME="Kaset"
# The one identifier Kaset ships under, and the only correct value for a build anyone
# installs. It ends up inside the app's code requirement - `codesign` records
# `identifier "<bundle id>"` - so a build with a different one (a different *case*
# counts: identifiers are case sensitive) has a different Keychain identity from the
# released app, and macOS asks for access to its own Keychain items again. Override it
# only for throwaway builds such as the Scripts/test-update-flow.sh harness.
CANONICAL_BUNDLE_ID="com.popcornfuzzy.Kaset"
BUNDLE_ID="${KASET_BUNDLE_ID:-$CANONICAL_BUNDLE_ID}"

# Ad-hoc signing has no stable requirement anyway, so a custom identifier costs nothing
# there; a certificate-signed build with the wrong identifier loses the "Always Allow"
# grant that the certificate was supposed to preserve.
if [[ "$SIGNING_MODE" != "adhoc" && "$BUNDLE_ID" != "$CANONICAL_BUNDLE_ID" ]]; then
  echo "WARN: building as '$BUNDLE_ID' instead of '$CANONICAL_BUNDLE_ID'."
  echo "      The bundle identifier is part of the code requirement, so this build has a"
  echo "      different Keychain identity from the app users install, and macOS will ask for"
  echo "      access to Kaset's Keychain items again. Only pass KASET_BUNDLE_ID for throwaway"
  echo "      builds. See docs/adr/0027-stable-code-signing-identity.md."
  echo ""
fi
SU_FEED_URL="${KASET_SU_FEED_URL:-https://raw.githubusercontent.com/popcornfuzzy/kaset/main/appcast.xml}"
SU_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_KEY:-o1vx9iHiGFhq2hdvof0Zv1pxf3uQSBxwSCW4WBDk2Wo=}"
BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Build for host architecture by default; allow overriding via ARCHES (e.g., "arm64 x86_64" for universal).
ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  case "$HOST_ARCH" in
    arm64) ARCH_LIST=(arm64) ;;
    x86_64) ARCH_LIST=(x86_64) ;;
    *) ARCH_LIST=("$HOST_ARCH") ;;
  esac
fi

echo "🔨 Building $APP_NAME ($CONF) for ${ARCH_LIST[*]}..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build for each architecture
for ARCH in "${ARCH_LIST[@]}"; do
  echo "  → Building for $ARCH..."
  swift build -c "$CONF" --arch "$ARCH"
done

# Create app bundle structure
echo "📦 Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Build path helper
build_product_path() {
  local name="$1"
  local arch="$2"
  # Ask SwiftPM where it actually put the product rather than guessing a layout.
  # The classic `.build/<arch>-apple-macosx/<conf>/` directory outlives the build
  # system that wrote it, so reading it can silently package a stale binary.
  local bin_dir
  bin_dir=$(swift build -c "$CONF" --arch "$arch" --show-bin-path | tail -n 1)
  echo "${bin_dir}/${name}"
}

# Verify binary architectures
verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

compile_asset_catalog() {
  local source_catalog="$1"
  local output_dir="$2"
  if [[ -d "$source_catalog" ]] && command -v actool &>/dev/null; then
    actool --compile "$output_dir" \
      --platform macosx \
      --minimum-deployment-target 26.0 \
      "$source_catalog" 2>/dev/null || true
  fi
}

# Install binary (handles universal builds)
install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

# Copy executable
install_binary "$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Refuse to package a binary that predates the sources: a stale product from another
# build system is worse than a failed build, because the app silently runs old code.
STALE_SOURCE=$(find Sources -name '*.swift' -newer "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -print -quit)
if [[ -n "$STALE_SOURCE" ]]; then
  echo "ERROR: Packaged binary is older than $STALE_SOURCE, so it does not contain the current sources." >&2
  exit 1
fi

# Generate Info.plist with build metadata
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ar</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>kaset</string>
    <key>CFBundleIconName</key>
    <string>kaset</string>
    <key>NSAccentColorName</key>
    <string>AccentColor</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 Sertac Ozercan. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>

    <!-- URL Scheme Registration -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
        <string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>kaset</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>

    <!-- Sparkle Auto-Update Configuration -->
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>

    <!-- Kaset is sandboxed, so Sparkle has to install updates from outside the sandbox
         through its Installer service. Without this key the updater submits the installer
         job itself, which the sandbox refuses, and every update fails after downloading.
         See docs/adr/0007-sparkle-auto-updates.md. -->
    <key>SUEnableInstallerLauncherService</key>
    <true/>

    <!-- AppleScript Support -->
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>Kaset.sdef</string>

    <!-- Google Cast discovery and audio streaming -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Kaset looks for Google Cast devices on your network and streams audio to the device you choose.</string>
    <!-- Required for the Core Audio process tap that captures playback while casting. Without this key
         macOS never prompts, and the tap runs but delivers silence. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Kaset captures the audio it is playing so it can send it to the Google Cast device you choose.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_googlecast._tcp</string>
    </array>

    <!-- Build Metadata -->
    <key>KasetBuildTimestamp</key>
    <string>${BUILD_TIMESTAMP}</string>
    <key>KasetGitCommit</key>
    <string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy AppleScript definition
SDEF_PATH="$ROOT/Sources/Kaset/Resources/Kaset.sdef"
if [[ -f "$SDEF_PATH" ]]; then
  echo "📜 Copying AppleScript definition..."
  cp "$SDEF_PATH" "$APP_BUNDLE/Contents/Resources/Kaset.sdef"
fi

# Copy app icon (.icon bundle for macOS 26+ Liquid Glass, .icns as fallback)
ICON_SOURCE="$ROOT/Sources/Kaset/Resources/kaset.png"
if [[ -d "$ICON_SOURCE" ]]; then
  echo "🎨 Copying app icon..."
  cp -R "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/kaset.png"
fi
ICNS_PATH="$ROOT/Sources/Kaset/Resources/kaset.png"
if [[ -f "$ICNS_PATH" ]]; then
  cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/kaset.png"
fi

# Compile asset catalog if actool is available
XCASSETS_PATH="$ROOT/Sources/Kaset/Resources/Assets.xcassets"
if [[ -d "$XCASSETS_PATH" ]] && command -v actool &>/dev/null; then
  echo "🎨 Compiling asset catalog..."
  compile_asset_catalog "$XCASSETS_PATH" "$APP_BUNDLE/Contents/Resources"
fi

# Embed Sparkle.framework
SPARKLE_FRAMEWORK=""
for arch in "${ARCH_LIST[@]}"; do
  CANDIDATE=$(build_product_path "" "$arch")
  CANDIDATE_DIR=$(dirname "$CANDIDATE")
  if [[ -d "$CANDIDATE_DIR/Sparkle.framework" ]]; then
    SPARKLE_FRAMEWORK="$CANDIDATE_DIR/Sparkle.framework"
    break
  fi
done

# Also check the default build path
if [[ -z "$SPARKLE_FRAMEWORK" ]] && [[ -d ".build/$CONF/Sparkle.framework" ]]; then
  SPARKLE_FRAMEWORK=".build/$CONF/Sparkle.framework"
fi

if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  echo "✨ Embedding Sparkle.framework..."
  cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
  chmod -R a+rX "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
  echo "WARN: Sparkle.framework not found in build output. Auto-updates will not work."
fi

# SwiftPM resource bundles are emitted next to the built binary
FIRST_ARCH="${ARCH_LIST[0]}"
BINARY_PATH=$(build_product_path "$APP_NAME" "$FIRST_ARCH")
PREFERRED_BUILD_DIR=$(dirname "$BINARY_PATH")
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    bundle_name=$(basename "$bundle")
    bundle_dest="$APP_BUNDLE/Contents/Resources/$bundle_name"
    echo "  → Copying resource bundle: $bundle_name"
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    # Resources live at the bundle root or under Contents/Resources, depending on the
    # build system that produced the bundle.
    for resources_root in "$bundle_dest" "$bundle_dest/Contents/Resources"; do
      if [[ -d "$resources_root/Assets.xcassets" ]] && command -v actool &>/dev/null; then
        echo "    ↳ Compiling bundle asset catalog"
        compile_asset_catalog "$resources_root/Assets.xcassets" "$resources_root"
        break
      fi
    done
  done

  # Mirror the packaged localizations into the app's top-level Resources
  # directory so both the SwiftPM resource bundle and Bundle.main lookups can
  # resolve them. Kaset ships .lproj/Localizable.strings files; a string catalog
  # must not be added alongside them, because SwiftPM would then emit two build
  # tasks for the same output path.
  # See docs/adr/0016-strings-files-as-localization-source-of-truth.md.
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    bundle_name=$(basename "$bundle")
    bundle_dest="$APP_BUNDLE/Contents/Resources/$bundle_name"

    # SwiftPM resource bundles either keep their resources at the bundle root
    # (classic .build layout) or under Contents/Resources (Swift Build layout).
    for resources_root in "$bundle_dest" "$bundle_dest/Contents/Resources"; do
      for lproj in "$resources_root"/*.lproj; do
        [[ -d "$lproj" ]] || continue
        lproj_name=$(basename "$lproj")
        echo "  → Copying localization: $lproj_name"
        mkdir -p "$APP_BUNDLE/Contents/Resources/$lproj_name"
        cp -R "$lproj/." "$APP_BUNDLE/Contents/Resources/$lproj_name/"
      done
    done
  done
fi

# Strip extended attributes to prevent AppleDouble (._*) files that break code sealing
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name '._*' -delete 2>/dev/null || true

# Sign the app
echo "🔏 Signing app..."
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  SIGNING_IDENTITY="-"
  TIMESTAMP_ARG=""
  APP_HARDENED_RUNTIME=0
elif [[ "$SIGNING_MODE" == "dev" ]]; then
  # Use Apple Development certificate
  CODESIGN_HASH=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
  if [[ -z "$CODESIGN_HASH" ]]; then
    echo "WARN: No Apple Development certificate found. Falling back to ad-hoc signing."
    SIGNING_IDENTITY="-"
  else
    SIGNING_IDENTITY="$CODESIGN_HASH"
  fi
  TIMESTAMP_ARG=""
  APP_HARDENED_RUNTIME=0
else
  SIGNING_IDENTITY="${APP_IDENTITY:-Developer ID Application}"
  TIMESTAMP_ARG="--timestamp"
  APP_HARDENED_RUNTIME=1
fi

if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  echo ""
  echo "WARN: signing ad-hoc. Every build gets a new code hash, so macOS asks for"
  echo "      Keychain access again after every install (Kaset's cookie archive and"
  echo "      Last.fm credentials). Sign with a certificate to avoid that:"
  echo "        KASET_SIGNING=dev Scripts/build-app.sh release          # local"
  echo "        KASET_SIGNING_P12=<base64 .p12> ... (CI secrets)        # workflow"
  echo "      See docs/adr/0027-stable-code-signing-identity.md."
  echo ""
fi

# codesign resolves an identity through the calling user's keychain search list. CI
# deliberately keeps the imported identity out of that list: Scripts/import-signing-identity.sh
# imports the .p12 into .build/signing.keychain-db so the build never touches the
# developer's own keychain. Without --keychain, codesign then reports
# "<hash>: no identity found" for an identity that `security find-identity <keychain>`
# lists happily, which is exactly how every signed CI build failed.
SIGNING_KEYCHAIN="${KASET_SIGNING_KEYCHAIN:-$ROOT/.build/signing.keychain-db}"

CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ -n "$APP_IDENTITY_EXPORTED" && -f "$SIGNING_KEYCHAIN" ]]; then
  CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
  echo "  → Identity from: $SIGNING_KEYCHAIN"
fi
if [[ -n "$TIMESTAMP_ARG" ]]; then
  CODESIGN_ARGS+=("$TIMESTAMP_ARG")
fi

# Only a Developer ID build enables the Hardened Runtime on the app itself: it is
# what a notarized build needs, while ad-hoc and development builds keep the
# signature they have always used.
APP_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}")
if [[ "$APP_HARDENED_RUNTIME" == "1" ]]; then
  APP_CODESIGN_ARGS+=(--options runtime)
fi

# Sparkle ships its helpers ad-hoc signed with the Hardened Runtime enabled, and
# re-signing them without that option changes their code requirements. Sparkle's
# own instructions for re-signing the framework are followed here, including
# preserving the Downloader service's entitlements and avoiding --deep (which is
# what breaks sandboxed installation).
# https://sparkle-project.org/documentation/sandboxing/#code-signing
sign_sparkle_component() {
  local target="$1"
  shift
  if [[ -n "$TIMESTAMP_ARG" ]]; then
    codesign --force --options runtime --timestamp "$@" --sign "$SIGNING_IDENTITY" "$target"
  else
    codesign --force --options runtime "$@" --sign "$SIGNING_IDENTITY" "$target"
  fi
}

SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  echo "  → Signing Sparkle.framework..."
  # Nested services and helper tools first, then the framework that contains them.
  if [[ -d "$SPARKLE/Versions/B/XPCServices/Installer.xpc" ]]; then
    sign_sparkle_component "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  fi
  if [[ -d "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" ]]; then
    sign_sparkle_component --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
      || sign_sparkle_component "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  fi
  if [[ -f "$SPARKLE/Versions/B/Autoupdate" ]]; then
    sign_sparkle_component "$SPARKLE/Versions/B/Autoupdate"
  fi
  if [[ -d "$SPARKLE/Versions/B/Updater.app" ]]; then
    sign_sparkle_component "$SPARKLE/Versions/B/Updater.app"
  fi
  sign_sparkle_component "$SPARKLE"
fi

# Sign the app bundle with entitlements. The bundled entitlements file uses
# $(PRODUCT_BUNDLE_IDENTIFIER), which Xcode expands but codesign does not, and
# Sparkle's Mach service exceptions are derived from the bundle identifier.
if [[ -f "$ROOT/Kaset.entitlements" ]]; then
  RENDERED_ENTITLEMENTS="$BUILD_DIR/Kaset.entitlements"
  "$ROOT/Scripts/generate-entitlements.sh" "$BUNDLE_ID" "$RENDERED_ENTITLEMENTS"
  codesign "${APP_CODESIGN_ARGS[@]}" --entitlements "$RENDERED_ENTITLEMENTS" "$APP_BUNDLE"
else
  codesign "${APP_CODESIGN_ARGS[@]}" "$APP_BUNDLE"
fi

echo ""
echo "✅ Build complete!"
echo "📍 App location: $APP_BUNDLE"
echo "   Version: ${MARKETING_VERSION} (${BUILD_NUMBER})"
echo "   Commit:  ${GIT_COMMIT}"
echo "   Arches:  ${ARCH_LIST[*]}"
echo ""
echo "To run: open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
