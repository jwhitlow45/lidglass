#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain for build-app.sh.
#
# macOS ties Screen Recording permission to how an app is signed. An ad-hoc signature
# names one exact binary, so every rebuild loses the permission. A certificate names the
# certificate instead, so the permission survives rebuilds signed with it.
set -euo pipefail

NAME="LidGlass Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The system LibreSSL writes PKCS#12 files that `security import` reads. OpenSSL 3's
# defaults do not.
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" is already in the login keychain"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The bundle's password only protects it on its way into the keychain.
PASSWORD="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD" -name "$NAME"

# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "created \"$NAME\" in the login keychain"
