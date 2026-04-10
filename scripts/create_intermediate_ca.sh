#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# You can override any of these at runtime, for example:
#   INTERMEDIATE_CA_OUTPUT_DIR=/tmp/intermediate-ca DAYS=3650 ./create_intermediate_ca.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-${SCRIPT_DIR}/../intermediate_ca}"
DAYS="${DAYS:-3650}"
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Intermediate CA}"
CN="${CN:-Example Intermediate CA}"

# OpenSSL configuration file to use (kept external to this script).
INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE:-../intermediate_ca/intermediate_ca.cnf}"

# --- Internal path layout ---------------------------------------------------
CERTS_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/certs"
CRL_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/crl"
CSR_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/csr"
NEWCERTS_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/newcerts"
PRIVATE_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/private"
EXPORT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/exports"

KEY_FILE="$PRIVATE_DIR/intermediate-ca.key.pem"
CSR_FILE="$CSR_DIR/intermediate-ca.csr.pem"

# Check that the script is being run as root.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: create_intermediate_ca.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

# Check that the configuration file exists.
if [ ! -f "$INTERMEDIATE_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL intermediate CA config not found: $INTERMEDIATE_CA_CONFIG_FILE" >&2
  echo "Set INTERMEDIATE_CA_CONFIG_FILE to the correct path and re-run." >&2
  exit 1
fi

echo "Initialising intermediate CA at: $INTERMEDIATE_CA_OUTPUT_DIR"
echo "Using OpenSSL config: $INTERMEDIATE_CA_CONFIG_FILE"

# Export variables so OpenSSL config can consume them through $ENV::... values.
export INTERMEDIATE_CA_OUTPUT_DIR DAYS ORG OU CN

# Create the directory skeleton needed by OpenSSL CA operations.
mkdir -p \
  "$CERTS_DIR" \
  "$CRL_DIR" \
  "$CSR_DIR" \
  "$NEWCERTS_DIR" \
  "$PRIVATE_DIR" \
  "$EXPORT_DIR"

# Restrict private key directory access to the owner only.
chmod 700 "$PRIVATE_DIR"

# OpenSSL CA database: index of issued certs.
if [ ! -f "$INTERMEDIATE_CA_OUTPUT_DIR/index.txt" ]; then
  touch "$INTERMEDIATE_CA_OUTPUT_DIR/index.txt"
fi

# Starting serial number for certificates signed by this CA.
if [ ! -f "$INTERMEDIATE_CA_OUTPUT_DIR/serial" ]; then
  echo 1000 | tee "$INTERMEDIATE_CA_OUTPUT_DIR/serial" >/dev/null
fi

# Generate the intermediate CA private key.
if [ -f "$KEY_FILE" ]; then
  echo "Intermediate CA private key already exists: $KEY_FILE"
else
  echo "Generating intermediate CA private key"
  # Generate a 4096-bit RSA private key used by the intermediate CA.
  openssl genpkey \
    -algorithm RSA \
    -out "$KEY_FILE" \
    -pkeyopt rsa_keygen_bits:4096
  # Private key should be readable only by root/owner.
  chmod 400 "$KEY_FILE"
fi

# Generate the intermediate CA certificate signing request.
if [ -f "$CSR_FILE" ]; then
  echo "Intermediate CA CSR already exists: $CSR_FILE"
else
  echo "Generating intermediate CA certificate signing request"
  # Create a CSR to be signed by the root CA.
  openssl req \
    -config "$INTERMEDIATE_CA_CONFIG_FILE" \
    -new \
    -sha256 \
    -key "$KEY_FILE" \
    -out "$CSR_FILE"
  # CSR is public material; world-readable is acceptable.
  chmod 444 "$CSR_FILE"
fi

echo

echo "Intermediate CA key and CSR created successfully."
echo "Private key:  $KEY_FILE"
echo "CSR:          $CSR_FILE"
echo "Config:       $INTERMEDIATE_CA_CONFIG_FILE"
echo
echo "Next step: sign the CSR with the root CA"
echo "  ./sign_intermediate_csr.sh"
