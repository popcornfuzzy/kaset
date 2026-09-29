#!/usr/bin/env bash
#
# generate-entitlements.sh - Renders Kaset.entitlements for one bundle identifier.
#
# Usage:
#   Scripts/generate-entitlements.sh <bundle-identifier> <output-path>
#
# The checked-in Kaset.entitlements file is written for Xcode, which expands
# $(PRODUCT_BUNDLE_IDENTIFIER) when it signs. Scripts/build-app.sh calls codesign
# directly, and codesign expands nothing, so the placeholder has to be resolved
# before signing.
#
# It matters because Sparkle names the Mach services its installer tools register
# after the *host* bundle identifier ("<bundle id>-spki" for the installer
# connection, "<bundle id>-spks" for installation status). An entitlement listing
# any other name - or none at all - leaves a sandboxed app able to download
# updates but unable to install them. See docs/adr/0007-sparkle-auto-updates.md.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

BUNDLE_ID="${1:-}"
OUTPUT="${2:-}"

if [[ -z "$BUNDLE_ID" || -z "$OUTPUT" ]]; then
  echo "Usage: $0 <bundle-identifier> <output-path>" >&2
  exit 64
fi

TEMPLATE="$ROOT/Kaset.entitlements"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: entitlements template not found: $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# Only the bundle identifier placeholder is substituted: any other $(...) in the
# template is an Xcode variable this script has no value for, and expanding it to
# nothing would silently ship a weaker entitlement set.
sed "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" "$TEMPLATE" > "$OUTPUT"

if grep -q 'PRODUCT_BUNDLE_IDENTIFIER' "$OUTPUT"; then
  echo "Error: \$(PRODUCT_BUNDLE_IDENTIFIER) was left unresolved in $OUTPUT" >&2
  exit 1
fi

if ! plutil -lint "$OUTPUT" >/dev/null 2>&1; then
  echo "Error: rendered entitlements are not a valid property list: $OUTPUT" >&2
  exit 1
fi
