#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/runtime"
KEYCHAIN_PATH="$RUNTIME_DIR/wallebrain-signing.keychain-db"
KEYCHAIN_PASSWORD="${WALLEBRAIN_KEYCHAIN_PASSWORD:-wallebrain-local-signing}"
IDENTITY_NAME="${WALLEBRAIN_CODESIGN_IDENTITY:-WalleBrain Local Signing}"

mkdir -p "$RUNTIME_DIR"

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

IDENTITY_OUTPUT="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null || true)"

if [[ "$IDENTITY_OUTPUT" != *"\"$IDENTITY_NAME\""* ]]; then
  rm -f "$KEYCHAIN_PATH"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wallebrain.codesign.XXXXXX")"
  OPENSSL_CONFIG="$TMP_DIR/openssl.cnf"
  KEY_FILE="$TMP_DIR/wallebrain.key"
  CERT_FILE="$TMP_DIR/wallebrain.crt"
  P12_FILE="$TMP_DIR/wallebrain.p12"
  P12_PASSWORD="wallebrain-p12"

  cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[ req_distinguished_name ]
CN = ${IDENTITY_NAME}
O = WalleBrain Local Development
C = CN

[ v3_codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" \
    -x509 -days 3650 \
    -out "$CERT_FILE" \
    -config "$OPENSSL_CONFIG" >/dev/null 2>&1

  openssl pkcs12 -export \
    -legacy \
    -inkey "$KEY_FILE" \
    -in "$CERT_FILE" \
    -name "$IDENTITY_NAME" \
    -out "$P12_FILE" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

  security import "$P12_FILE" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASSWORD" \
    -f pkcs12 \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" "$CERT_FILE" >/dev/null 2>&1 || true

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

  rm -rf "$TMP_DIR"
fi

echo "$KEYCHAIN_PATH"
