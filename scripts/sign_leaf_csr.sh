#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# This script signs leaf CSRs with the intermediate CA.
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}"
DAYS="${DAYS:-825}"
INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE:-../intermediate_ca/intermediate_ca.cnf}"

# --- Internal paths ---------------------------------------------------------
INTERMEDIATE_CERT_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/intermediate-ca.cert.pem"
LEAF_CERTS_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/certs"
LEAF_EXPORT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/export"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: sign_leaf_csr.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path-to-leaf-csr>" >&2
  exit 1
fi

LEAF_CSR_FILE="$1"

if [ ! -f "$LEAF_CSR_FILE" ]; then
  echo "Error: leaf CSR not found: $LEAF_CSR_FILE" >&2
  exit 1
fi

if [ ! -f "$INTERMEDIATE_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL intermediate CA config not found: $INTERMEDIATE_CA_CONFIG_FILE" >&2
  exit 1
fi

if [ ! -f "$INTERMEDIATE_CERT_FILE" ]; then
  echo "Error: intermediate CA certificate not found: $INTERMEDIATE_CERT_FILE" >&2
  echo "Sign the intermediate CA first." >&2
  exit 1
fi

export INTERMEDIATE_CA_OUTPUT_DIR DAYS

mkdir -p "$LEAF_CERTS_DIR" "$LEAF_EXPORT_DIR"

CSR_BASENAME="$(basename "$LEAF_CSR_FILE")"
LEAF_CERT_FILE="$LEAF_CERTS_DIR/${CSR_BASENAME/.csr.pem/.cert.pem}"

if [ -f "$LEAF_CERT_FILE" ]; then
  echo "Leaf certificate already exists: $LEAF_CERT_FILE"
else
  echo "Signing leaf CSR with intermediate CA"
  openssl ca \
    -config "$INTERMEDIATE_CA_CONFIG_FILE" \
    -extensions usr_cert \
    -days "$DAYS" \
    -notext \
    -md sha256 \
    -batch \
    -in "$LEAF_CSR_FILE" \
    -out "$LEAF_CERT_FILE"
  chmod 444 "$LEAF_CERT_FILE"
fi

cp "$LEAF_CERT_FILE" "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"
chmod 444 "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"

echo
echo "Leaf certificate created successfully."
echo "Certificate: $LEAF_CERT_FILE"
