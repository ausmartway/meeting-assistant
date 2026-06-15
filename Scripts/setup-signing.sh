#!/usr/bin/env bash
# Create a stable, self-signed code-signing certificate so the app keeps ONE
# identity across rebuilds.
#
# WHY THIS MATTERS: macOS ties TCC permission grants (Screen & Audio Recording,
# Accessibility) to the app's code-signing identity. Ad-hoc signing has no stable
# identity — every build looks like a brand-new app — so those grants silently
# reset on each new version (the checkbox stays on in System Settings, but the app
# can't actually use the permission). A self-signed certificate gives the app a
# constant identity, so you grant once and it sticks across future local builds.
#
# The cert + private key live in a DEDICATED keychain (not your login keychain),
# unlocked with a random password stored locally at ~/.config/meeting-assistant/.
# Nothing leaves this Mac. Run this ONCE, then build/install with
# ./Scripts/install.sh as usual.
#
# (Self-signed is not Apple-notarized, so the first launch of each install still
# needs System Settings → Privacy & Security → Open Anyway.)
set -euo pipefail

IDENTITY="Meeting Assistant Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/meeting-assistant-signing.keychain-db"
PW_DIR="$HOME/.config/meeting-assistant"
PW_FILE="$PW_DIR/signing-keychain-password"

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ Signing identity already present in $KEYCHAIN"
  echo "  Nothing to do — build with ./Scripts/install.sh"
  exit 0
fi

echo "▸ Generating self-signed code-signing certificate…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY/O=Meeting Assistant" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS's `security import` needs the legacy PKCS#12 encoding (OpenSSL 3 defaults
# to a newer MAC algorithm it can't read).
P12PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:"$P12PASS" -name "$IDENTITY" -legacy 2>/dev/null

# A random password for the dedicated keychain, saved locally (owner-only) so
# builds can unlock it without a GUI prompt.
mkdir -p "$PW_DIR"; chmod 700 "$PW_DIR"
KCPASS="$(openssl rand -hex 24)"
printf '%s' "$KCPASS" > "$PW_FILE"; chmod 600 "$PW_FILE"

echo "▸ Creating dedicated signing keychain…"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
# Don't auto-lock during builds.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

echo "▸ Importing certificate…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign
# Pre-authorize codesign to use the key non-interactively.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null 2>&1

# Add the keychain to the user search list (idempotent) so codesign can find it.
EXISTING="$(security list-keychains -d user | tr -d '"' | xargs)"
case " $EXISTING " in
  *" $KEYCHAIN "*) : ;;  # already listed
  *) security list-keychains -d user -s $EXISTING "$KEYCHAIN" ;;
esac

echo "✓ Created signing identity: $IDENTITY"
echo "  Keychain:  $KEYCHAIN"
echo "  Password:  $PW_FILE (owner-only)"
echo
echo "Next:"
echo "  ./Scripts/install.sh --run     # builds, signs with this identity, installs"
echo
echo "After installing, grant Screen & Audio Recording (and Accessibility) once —"
echo "from now on the grants persist across rebuilds."
