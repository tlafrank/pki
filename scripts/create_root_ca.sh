#!/usr/bin/env bash
set -euo pipefail

ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-/opt/pki/root-ca}"
DAYS="${DAYS:-7300}"
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Root CA}"
CN="${CN:-Example Root CA}"

CERTS_DIR="$ROOT_CA_OUTPUT_DIR/certs"
CRL_DIR="$ROOT_CA_OUTPUT_DIR/crl"
CSR_DIR="$ROOT_CA_OUTPUT_DIR/csr"
NEWCERTS_DIR="$ROOT_CA_OUTPUT_DIR/newcerts"
PRIVATE_DIR="$ROOT_CA_OUTPUT_DIR/private"
EXPORT_DIR="$ROOT_CA_OUTPUT_DIR/export"

CONFIG_FILE="../root_CA/root.cnf"
KEY_FILE="$PRIVATE_DIR/root-ca.key.pem"
CERT_FILE="$CERTS_DIR/root-ca.cert.pem"

echo "Initialising root CA at: $ROOT_CA_OUTPUT_DIR"

sudo mkdir -p \
  "$CERTS_DIR" \
  "$CRL_DIR" \
  "$CSR_DIR" \
  "$NEWCERTS_DIR" \
  "$PRIVATE_DIR" \
  "$EXPORT_DIR"

sudo chmod 700 "$PRIVATE_DIR"

#Create the OpenSSL CA database file, if it doesn't already exist.
if [ ! -f "$ROOT_CA_OUTPUT_DIR/index.txt" ]; then
  sudo touch "$ROOT_CA_OUTPUT_DIR/index.txt"
fi

if [ ! -f "$ROOT_CA_OUTPUT_DIR/serial" ]; then
  echo 1000 | sudo tee "$ROOT_CA_OUTPUT_DIR/serial" >/dev/null
fi

echo "Writing OpenSSL config: $CONFIG_FILE"

sudo tee "$CONFIG_FILE" >/dev/null <<EOF
EOF

if [ -f "$KEY_FILE" ]; then
  echo "Root CA private key already exists: $KEY_FILE"
else
  echo "Generating root CA private key"
  sudo openssl genpkey \
    -algorithm RSA \
    -out "$KEY_FILE" \
    -pkeyopt rsa_keygen_bits:4096
  sudo chmod 400 "$KEY_FILE"
fi

if [ -f "$CERT_FILE" ]; then
  echo "Root CA certificate already exists: $CERT_FILE"
else
  echo "Generating self-signed root CA certificate"
  sudo openssl req \
    -config "$CONFIG_FILE" \
    -key "$KEY_FILE" \
    -new -x509 \
    -days "$DAYS" \
    -sha256 \
    -extensions v3_root_ca \
    -out "$CERT_FILE"
  sudo chmod 444 "$CERT_FILE"
fi

echo "Packaging root certificate"
sudo cp "$CERT_FILE" "$EXPORT_DIR/root-ca.pem"
sudo chmod 444 "$EXPORT_DIR/root-ca.pem"

sudo openssl x509 -in "$CERT_FILE" -out "$EXPORT_DIR/root-ca.crt"
sudo chmod 444 "$EXPORT_DIR/root-ca.crt"

sudo openssl x509 -in "$CERT_FILE" -outform DER -out "$EXPORT_DIR/root-ca.der"
sudo chmod 444 "$EXPORT_DIR/root-ca.der"

echo
echo "Root CA created successfully."
echo "Private key:  $KEY_FILE"
echo "Certificate:  $CERT_FILE"
echo "Exports:"
echo "  $EXPORT_DIR/root-ca.pem"
echo "  $EXPORT_DIR/root-ca.crt"
echo "  $EXPORT_DIR/root-ca.der"
echo
echo "Inspect with:"
echo "  openssl x509 -in $CERT_FILE -noout -text"
