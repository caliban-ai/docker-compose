#!/usr/bin/env bash
# Generate a self-signed CA + caliband server certificate for the network
# overlay (overlays/network.yaml). Writes to ./certs:
#
#   ca.crt / ca.key          the local CA
#   caliband.crt / .key      server cert, SAN = DNS:caliban (the compose service)
#
# The server cert's SAN is the compose service name `caliban`, which is how
# prospero reaches it on the compose network. Re-run to rotate.
#
# BETA: caliband network mode is still hardening (caliban #319/#320).
set -euo pipefail

cd "$(dirname "$0")/.."
CERT_DIR="./certs"
DAYS="${CERT_DAYS:-825}"
SVC="${CALIBAN_SERVICE_NAME:-caliban}"

mkdir -p "$CERT_DIR"

echo "==> CA"
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days "$DAYS" \
  -subj "/CN=caliban-ai local CA" -out "$CERT_DIR/ca.crt"

echo "==> caliband server cert (SAN=DNS:$SVC)"
openssl genrsa -out "$CERT_DIR/caliband.key" 4096 2>/dev/null
openssl req -new -key "$CERT_DIR/caliband.key" \
  -subj "/CN=$SVC" -out "$CERT_DIR/caliband.csr"
openssl x509 -req -in "$CERT_DIR/caliband.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 \
  -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost\nextendedKeyUsage=serverAuth\n' "$SVC") \
  -out "$CERT_DIR/caliband.crt"
rm -f "$CERT_DIR/caliband.csr" "$CERT_DIR/ca.srl"

# The caliban container runs as uid 10001 and reads these via a read-only bind
# mount, so the key must be world-readable. This is acceptable for a single-host
# self-host deployment; treat ./certs as sensitive (it is gitignored).
chmod 0644 "$CERT_DIR"/*.crt "$CERT_DIR"/*.key

echo "==> done. Files in $CERT_DIR:"
ls -1 "$CERT_DIR"
