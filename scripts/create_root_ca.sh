#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# You can override any of these at runtime, for example:
#   ROOT_CA_OUTPUT_DIR=/tmp/root_ca DAYS=3650 ./create_root_ca.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-${SCRIPT_DIR}/../root_ca}"
DAYS="${DAYS:-7300}"
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Root CA}"
CN="${CN:-Example Root CA}"

# OpenSSL configuration file to use (kept external to this script).
ROOT_CA_CONFIG_FILE="${ROOT_CA_CONFIG_FILE:-${SCRIPT_DIR}/../root_ca/root_ca.cnf}"

# --- Internal path layout ---------------------------------------------------
# OpenSSL's CA tooling expects these files/directories to exist.
CERTS_DIR="$ROOT_CA_OUTPUT_DIR/certs"
CRL_DIR="$ROOT_CA_OUTPUT_DIR/crl"
CSR_DIR="$ROOT_CA_OUTPUT_DIR/csr"
NEWCERTS_DIR="$ROOT_CA_OUTPUT_DIR/newcerts"
PRIVATE_DIR="$ROOT_CA_OUTPUT_DIR/private"
EXPORT_DIR="$ROOT_CA_OUTPUT_DIR/exports"

KEY_FILE="$PRIVATE_DIR/root-ca.key.pem"
CERT_FILE="$CERTS_DIR/root-ca.cert.pem"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: create_root_ca.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
fi

# Check that the configuration file exists
if [ ! -f "$ROOT_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL root CA config not found: $ROOT_CA_CONFIG_FILE" >&2
  echo "Set ROOT_CA_CONFIG_FILE to the correct path and re-run." >&2
  exit 1
fi

echo "Initialising root CA at: $ROOT_CA_OUTPUT_DIR"
echo "Using OpenSSL config: $ROOT_CA_CONFIG_FILE"

# Export variables so OpenSSL config can consume them through $ENV::... values.
export ROOT_CA_OUTPUT_DIR DAYS ORG OU CN

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
if [ ! -f "$ROOT_CA_OUTPUT_DIR/index.txt" ]; then
  touch "$ROOT_CA_OUTPUT_DIR/index.txt"
fi

# Starting serial number for certificates signed by this CA.
if [ ! -f "$ROOT_CA_OUTPUT_DIR/serial" ]; then
  echo 1000 | tee "$ROOT_CA_OUTPUT_DIR/serial" >/dev/null
fi

# Generate the root CA private key
if [ -f "$KEY_FILE" ]; then
  echo "Root CA private key already exists: $KEY_FILE"
else
  echo "Generating root CA private key"
  # Generate a 4096-bit RSA private key used to sign certificates.
  openssl genpkey \
    -algorithm RSA \
    -out "$KEY_FILE" \
    -pkeyopt rsa_keygen_bits:4096
  # Private key should be readable only by root/owner.
  chmod 400 "$KEY_FILE"
fi

# 
if [ -f "$CERT_FILE" ]; then
  echo "Root CA certificate already exists: $CERT_FILE"
else
  echo "Generating self-signed root CA certificate"
  # Create a self-signed X.509 root certificate from the private key.
  openssl req \
    -config "$ROOT_CA_CONFIG_FILE" \
    -key "$KEY_FILE" \
    -new -x509 \
    -days "$DAYS" \
    -sha256 \
    -extensions v3_root_ca \
    -out "$CERT_FILE"
  # Certificates are public material; world-readable is acceptable.
  chmod 444 "$CERT_FILE"
fi

echo "Packaging root certificate"
# PEM copy with an easy-to-share/export-friendly name.
cp "$CERT_FILE" "$EXPORT_DIR/root-ca.pem"
chmod 444 "$EXPORT_DIR/root-ca.pem"

# CRT (PEM encoding, .crt extension) for tools that expect that extension.
#openssl x509 -in "$CERT_FILE" -out "$EXPORT_DIR/root-ca.crt"
#chmod 444 "$EXPORT_DIR/root-ca.crt"

# DER (binary) encoding for platforms/import flows requiring DER certificates.
#openssl x509 -in "$CERT_FILE" -outform DER -out "$EXPORT_DIR/root-ca.der"
#chmod 444 "$EXPORT_DIR/root-ca.der"

echo
echo "Root CA created successfully."
echo "Private key:  $KEY_FILE"
echo "Certificate:  $CERT_FILE"
echo "Config:       $ROOT_CA_CONFIG_FILE"
echo "Exports:"
echo "  $EXPORT_DIR/root-ca.pem"
#echo "  $EXPORT_DIR/root-ca.crt"
#echo "  $EXPORT_DIR/root-ca.der"
echo
echo "Inspect created certificate with:"
echo "  openssl x509 -in $CERT_FILE -noout -text"
