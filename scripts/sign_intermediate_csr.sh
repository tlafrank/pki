#!/usr/bin/env bash
set -euo pipefail

# --- Fixed root CA location -------------------------------------------------
# This script is intentionally limited to the root CA host layout.
ROOT_CA_OUTPUT_DIR="/opt/pki/root_ca"
DAYS="${DAYS:-3650}"

# OpenSSL configuration file for the signing CA (root CA).
ROOT_CA_CONFIG_FILE="${ROOT_CA_CONFIG_FILE:-$ROOT_CA_OUTPUT_DIR/root_ca.cnf}"

ROOT_CERT_FILE="$ROOT_CA_OUTPUT_DIR/certs/root-ca.cert.pem"

# Check that the script is being run as root.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: sign_intermediate_csr.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path-to-intermediate-csr>" >&2
  exit 1
fi

INTERMEDIATE_CSR_FILE="$1"

if [ ! -f "$INTERMEDIATE_CSR_FILE" ]; then
  echo "Error: intermediate CA CSR not found: $INTERMEDIATE_CSR_FILE" >&2
  exit 1
fi

# Resolve output locations under the fixed root CA directory structure.
CERTS_DIR="$ROOT_CA_OUTPUT_DIR/certs"
EXPORT_DIR="$ROOT_CA_OUTPUT_DIR/export"
CSR_BASENAME="$(basename "$INTERMEDIATE_CSR_FILE")"
CERT_BASENAME="${CSR_BASENAME/.csr.pem/.cert.pem}"
INTERMEDIATE_CERT_FILE="$CERTS_DIR/$CERT_BASENAME"
CHAIN_FILE="$CERTS_DIR/ca-chain.cert.pem"

# Check that the root CA configuration file exists.
if [ ! -f "$ROOT_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL root CA config not found: $ROOT_CA_CONFIG_FILE" >&2
  echo "Set ROOT_CA_CONFIG_FILE to the correct path and re-run." >&2
  exit 1
fi

# Check prerequisite root CA artifacts.
if [ ! -f "$ROOT_CERT_FILE" ]; then
  echo "Error: root CA certificate not found: $ROOT_CERT_FILE" >&2
  echo "Run create_root_ca.sh first (or set ROOT_CA_OUTPUT_DIR)." >&2
  exit 1
fi

# Export values consumed by $ENV::... references in the root CA config.
export ROOT_CA_OUTPUT_DIR DAYS

# Ensure output folders exist.
mkdir -p "$CERTS_DIR" "$EXPORT_DIR"

# Sign the intermediate CSR with the root CA key/certificate.
if [ -f "$INTERMEDIATE_CERT_FILE" ]; then
  echo "Intermediate CA certificate already exists: $INTERMEDIATE_CERT_FILE"
else
  echo "Signing intermediate CA CSR with root CA"
  # Use the root CA policy and v3_intermediate_ca extension set from root_ca.cnf.
  openssl ca \
    -config "$ROOT_CA_CONFIG_FILE" \
    -extensions v3_intermediate_ca \
    -days "$DAYS" \
    -notext \
    -md sha256 \
    -batch \
    -in "$INTERMEDIATE_CSR_FILE" \
    -out "$INTERMEDIATE_CERT_FILE"
  # Certificates are public material; world-readable is acceptable.
  chmod 444 "$INTERMEDIATE_CERT_FILE"
fi

# Build a chain file ordered as intermediate -> root.
echo "Creating certificate chain"
cat "$INTERMEDIATE_CERT_FILE" "$ROOT_CERT_FILE" > "$CHAIN_FILE"
chmod 444 "$CHAIN_FILE"

# Export copies with simple names for downstream tooling.
cp "$INTERMEDIATE_CERT_FILE" "$EXPORT_DIR/intermediate-ca.pem"
cp "$CHAIN_FILE" "$EXPORT_DIR/ca-chain.pem"
chmod 444 "$EXPORT_DIR/intermediate-ca.pem" "$EXPORT_DIR/ca-chain.pem"

echo

echo "Intermediate CA certificate created successfully."
echo "Intermediate cert: $INTERMEDIATE_CERT_FILE"
echo "Chain file:        $CHAIN_FILE"
echo "Exports:"
echo "  $EXPORT_DIR/intermediate-ca.pem"
echo "  $EXPORT_DIR/ca-chain.pem"
echo
echo "Inspect created certificate with:"
echo "  openssl x509 -in $INTERMEDIATE_CERT_FILE -noout -text"
