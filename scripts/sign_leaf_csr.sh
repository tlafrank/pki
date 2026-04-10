#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# This script signs leaf CSRs with the intermediate CA.
# You can override defaults at runtime, for example:
#   INTERMEDIATE_CA_OUTPUT_DIR=/opt/pki/intermediate-ca DAYS=397 ./sign_leaf_csr.sh ./csr/web.csr.pem
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}"
DAYS="${DAYS:-825}"
INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE:-../intermediate_ca/intermediate_ca.cnf}"

# --- Internal paths ---------------------------------------------------------
INTERMEDIATE_CERT_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/intermediate-ca.cert.pem"
LEAF_CERTS_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/certs"
LEAF_EXPORT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/export"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: sign_leaf_csr.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
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

# Export values consumed by $ENV::... references in intermediate_ca.cnf.
export INTERMEDIATE_CA_OUTPUT_DIR DAYS

# Ensure expected output directories exist.
mkdir -p "$LEAF_CERTS_DIR" "$LEAF_EXPORT_DIR"

# Convert foo.csr.pem -> foo.cert.pem while preserving basename convention.
CSR_BASENAME="$(basename "$LEAF_CSR_FILE")"
LEAF_CERT_FILE="$LEAF_CERTS_DIR/${CSR_BASENAME/.csr.pem/.cert.pem}"

if [ -f "$LEAF_CERT_FILE" ]; then
  echo "Leaf certificate already exists: $LEAF_CERT_FILE"
else
  echo "Signing leaf CSR with intermediate CA"
  # Use intermediate CA policy and leaf extension profile from config.
  openssl ca \
    -config "$INTERMEDIATE_CA_CONFIG_FILE" \
    -extensions usr_cert \
    -days "$DAYS" \
    -notext \
    -md sha256 \
    -batch \
    -in "$LEAF_CSR_FILE" \
    -out "$LEAF_CERT_FILE"
  # Certificates are public material; world-readable is acceptable.
  chmod 444 "$LEAF_CERT_FILE"
fi

# Export a copy with a predictable filename in the export folder.
cp "$LEAF_CERT_FILE" "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"
chmod 444 "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"

echo
echo "Leaf certificate created successfully."
echo "Certificate: $LEAF_CERT_FILE"
