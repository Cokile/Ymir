#!/usr/bin/env bash
set -euo pipefail

# Creates a stable self-signed code-signing identity in the login keychain.
# Signing Ymir with a constant identity keeps its code signature stable across
# rebuilds, so macOS TCC permissions (notifications, etc.) persist instead of
# resetting every time (which happens with ad-hoc "Sign to Run Locally").
#
# Idempotent: does nothing if the certificate already exists.
# Override the name with:  SIGN_IDENTITY="My Cert" scripts/make_signing_cert.sh

IDENTITY="${SIGN_IDENTITY:-Ymir Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity already present: $IDENTITY"
  exit 0
fi

echo "==> Creating self-signed code-signing certificate: $IDENTITY"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# RSA key + self-signed cert carrying the code-signing extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle key + cert into a PKCS#12 for import. Use -legacy so macOS's
# security(1) can parse it (OpenSSL 3's default format is incompatible), and a
# throwaway passphrase (empty passphrases trip the importer's MAC check).
PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:"$PW" -name "$IDENTITY"

# Import into the login keychain. -A lets codesign use the key without an
# interactive keychain prompt; -T also whitelists the codesign tool.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PW" -A -T /usr/bin/codesign

echo "==> Installed signing identity: $IDENTITY"
