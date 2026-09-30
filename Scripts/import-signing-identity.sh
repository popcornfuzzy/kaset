#!/usr/bin/env bash
#
# import-signing-identity.sh - Imports a code signing identity into a scoped keychain.
#
# Usage:
#   KASET_SIGNING_P12=<base64 .p12> KASET_SIGNING_P12_PASSWORD=<password> \
#     Scripts/import-signing-identity.sh
#   Scripts/import-signing-identity.sh --cleanup
#
# Prints the imported identity's fingerprint on stdout, ready to pass to codesign as
# APP_IDENTITY. Prints nothing and exits 0 when no identity was supplied, so callers
# can fall back to ad-hoc signing.
#
# Why this exists: an ad-hoc signature has no certificate, so its designated
# requirement is a cdhash that changes on every build. macOS keys Keychain item access
# to the accessing app's designated requirement, which means an ad-hoc app has to be
# granted access to its own Keychain items again after every install - three prompts
# for Kaset's cookie archive and Last.fm credentials. Signing with a certificate makes
# the requirement stable, so "Always Allow" survives the next install.
# See docs/adr/0027-stable-code-signing-identity.md.
#
# The keychain is written inside .build/ so nothing touches the login keychain, and
# --cleanup removes it when a workflow finishes.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Warnings become workflow annotations in CI, where nobody is reading the raw log.
warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$1" >&2
  else
    echo "Warning: $1" >&2
  fi
}

KEYCHAIN_PATH="${KASET_SIGNING_KEYCHAIN:-$ROOT/.build/signing.keychain-db}"
KEYCHAIN_PASSWORD="${KASET_SIGNING_KEYCHAIN_PASSWORD:-kaset-signing}"
P12_BASE64="${KASET_SIGNING_P12:-}"
P12_PASSWORD="${KASET_SIGNING_P12_PASSWORD:-}"

# The search list is saved here so --cleanup can put it back exactly as it was.
SEARCH_LIST_BACKUP="${KEYCHAIN_PATH}.search-list"

if [[ "${1:-}" == "--cleanup" ]]; then
  if [[ -f "$SEARCH_LIST_BACKUP" ]]; then
    ORIGINAL_KEYCHAINS=()
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then ORIGINAL_KEYCHAINS+=("$line"); fi
    done < "$SEARCH_LIST_BACKUP"
    # bash 3.2 (macOS) treats "${empty[@]}" as an unbound variable under set -u.
    if [[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    fi
    rm -f "$SEARCH_LIST_BACKUP"
  fi
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  exit 0
fi

# No identity configured: the caller decides what that means (a warning, ad-hoc
# signing, or a hard failure).
if [[ -z "$P12_BASE64" ]]; then
  exit 0
fi

if [[ -z "$P12_PASSWORD" ]]; then
  echo "Error: KASET_SIGNING_P12 is set but KASET_SIGNING_P12_PASSWORD is not." >&2
  exit 1
fi

# BSD base64 spells the flag -D, GNU coreutils spells it --decode.
if printf 'aGVsbG8=' | base64 --decode >/dev/null 2>&1; then
  DECODE=(base64 --decode)
else
  DECODE=(base64 -D)
fi

# Nothing this script writes is meant to be readable by anyone else.
umask 077

# The staged .p12 lives beside the keychain, not in $TMPDIR: `security import`
# rejects a PKCS#12 read from a per-user temp directory, reporting "Unknown format
# in import" for bytes it imports happily from anywhere else. That failure looks
# like a corrupt secret and is worth not rediscovering.
KEYCHAIN_DIR=$(dirname "$KEYCHAIN_PATH")
mkdir -p "$KEYCHAIN_DIR"
STAGED_P12="$KEYCHAIN_DIR/signing-import.$$.p12"
trap 'rm -f "$STAGED_P12"' EXIT

printf '%s' "$P12_BASE64" | "${DECODE[@]}" > "$STAGED_P12"

if [[ ! -s "$STAGED_P12" ]]; then
  echo "Error: KASET_SIGNING_P12 did not decode to any bytes." >&2
  exit 1
fi

rm -f "$KEYCHAIN_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

if ! security import "$STAGED_P12" -k "$KEYCHAIN_PATH" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
  echo "Error: could not import the signing identity. Check that KASET_SIGNING_P12 holds" >&2
  echo "a base64 .p12 and that KASET_SIGNING_P12_PASSWORD is its password." >&2
  exit 1
fi

# Without this, codesign still shows a keychain prompt on macOS; a CI runner has
# nobody to click it, so signing would hang.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# A brand-new keychain is not on the calling user's keychain search list, and that is
# where codesign looks for an identity. build-app.sh passes --keychain, which is what
# actually signs; this registration is for everything else that only knows the search
# list (Xcode's tooling, `security find-identity` without arguments). The original list
# is saved so --cleanup restores it rather than leaving a dangling path behind.
security list-keychains -d user \
  | sed 's/^[[:space:]]*//;s/"//g' > "$SEARCH_LIST_BACKUP"
PREVIOUS_KEYCHAINS=()
while IFS= read -r line; do
  if [[ -n "$line" ]]; then PREVIOUS_KEYCHAINS+=("$line"); fi
done < "$SEARCH_LIST_BACKUP"
if [[ ${#PREVIOUS_KEYCHAINS[@]} -gt 0 ]]; then
  security list-keychains -d user -s "$KEYCHAIN_PATH" "${PREVIOUS_KEYCHAINS[@]}" >/dev/null
else
  security list-keychains -d user -s "$KEYCHAIN_PATH" >/dev/null
fi

# -v lists only identities whose certificate chain Apple trusts. A self-signed
# certificate is still usable for signing and still gives the app a stable
# designated requirement, so fall back to the unfiltered listing rather than
# failing, but say so.
IDENTITY_LINE=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
  | awk '/^[[:space:]]*[0-9]+\)/ { print; exit }')
if [[ -z "$IDENTITY_LINE" ]]; then
  IDENTITY_LINE=$(security find-identity -p codesigning "$KEYCHAIN_PATH" \
    | awk '/^[[:space:]]*[0-9]+\)/ { print; exit }')
  if [[ -n "$IDENTITY_LINE" ]]; then
    warn "the imported certificate is not Apple-trusted. It still signs and still gives the app a stable identity, but expect Gatekeeper to treat the app like an unsigned one."
  fi
fi

if [[ -z "$IDENTITY_LINE" ]]; then
  echo "Error: the .p12 imported but contains no code signing identity." >&2
  echo "Export the *identity* from Keychain Access under 'My Certificates' (the certificate" >&2
  echo "with its private key attached), not the certificate on its own." >&2
  exit 1
fi

IDENTITY=$(echo "$IDENTITY_LINE" | awk '{ print $2 }')
echo "Imported signing identity:$IDENTITY_LINE" >&2

# Report the expiry date, and complain two months ahead of it. An Apple
# Development certificate lasts a year and Xcode renews it silently for your own
# machine, but CI keeps using whatever is in the secret - and a renewed
# certificate has a different leaf hash, so every install prompts for Keychain
# access once more. Renewing on purpose beats discovering it at release time.
CERT_NAME=$(echo "$IDENTITY_LINE" | sed -n 's/^[[:space:]]*[0-9]*) [^ ]* "\(.*\)".*/\1/p')
CERT_PEM=$(security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN_PATH" 2>/dev/null || true)
if [[ -n "$CERT_PEM" ]]; then
  END_DATE=$(echo "$CERT_PEM" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
  if [[ -n "$END_DATE" ]]; then
    echo "Certificate valid until: $END_DATE" >&2
    # 5184000 seconds is 60 days.
    if ! echo "$CERT_PEM" | openssl x509 -noout -checkend 5184000 >/dev/null 2>&1; then
      warn "the signing certificate expires within 60 days (or has already expired). Renew it, export a fresh .p12, and update KASET_SIGNING_P12. Existing installs will ask for Keychain access once more afterwards. See docs/adr/0027-stable-code-signing-identity.md."
    fi
  fi
fi

echo "$IDENTITY"
