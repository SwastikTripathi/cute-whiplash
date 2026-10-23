#!/usr/bin/env bash
# Ensures a stable, self-signed code-signing identity exists and prints its SHA-1.
#
# Why: an ad-hoc signature is keyed to the binary's hash, so macOS forgets the Screen Recording grant after every
# rebuild. A certificate-based signature gives the app the same identity across rebuilds, so one grant sticks.
#
# The identity lives in its own keychain (.signing/whiplash.keychain-db, never added to the search list), so the
# login keychain is untouched and nothing prompts for a password. Delete .signing/ to start over (macOS will then
# ask for Screen Recording once more).
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=".signing"
KEYCHAIN="$PWD/$DIR/whiplash.keychain-db"
PASS="whiplash-local-signing" # not a secret: the keychain only holds this throwaway local certificate
NAME="Whiplash Local Signing"

if [ ! -f "$KEYCHAIN" ]; then
    mkdir -p "$DIR"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
        -out "$TMP/identity.p12" -passout pass:"$PASS" 2>/dev/null
    security create-keychain -p "$PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN" # no auto-lock
    security unlock-keychain -p "$PASS" "$KEYCHAIN"
    security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$PASS" "$KEYCHAIN"
# Self-signed, so it is listed as untrusted; codesign still signs with it when named by hash.
security find-identity -p codesigning "$KEYCHAIN" | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }'
