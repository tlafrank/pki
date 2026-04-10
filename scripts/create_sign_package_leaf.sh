#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}"
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR:-$INTERMEDIATE_CA_OUTPUT_DIR/leaf}"
LEAF_CONFIG_FILE="${LEAF_CONFIG_FILE:-../intermediate_ca/intermediate_ca.cnf}"
DAYS="${DAYS:-825}"
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Leaf Certificates}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: create_sign_package_leaf.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <leaf-common-name> <p12-password>" >&2
  exit 1
fi

LEAF_CN="$1"
P12_PASSWORD="$2"

if [ -z "$P12_PASSWORD" ]; then
  echo "Error: p12 password cannot be empty." >&2
  exit 1
fi

mkdir -p "$LEAF_OUTPUT_DIR" "$LEAF_OUTPUT_DIR/private" "$LEAF_OUTPUT_DIR/csr" "$LEAF_OUTPUT_DIR/certs" "$LEAF_OUTPUT_DIR/export"

KEY_FILE="$LEAF_OUTPUT_DIR/private/${LEAF_CN}.key.pem"
CSR_FILE="$LEAF_OUTPUT_DIR/csr/${LEAF_CN}.csr.pem"
CERT_FILE="$LEAF_OUTPUT_DIR/certs/${LEAF_CN}.cert.pem"
P12_FILE="$LEAF_OUTPUT_DIR/export/${LEAF_CN}.p12"
CHAIN_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/ca-chain.cert.pem"

if [ ! -f "$LEAF_CONFIG_FILE" ]; then
  echo "Error: OpenSSL intermediate CA config not found: $LEAF_CONFIG_FILE" >&2
  exit 1
fi

if [ ! -f "$CHAIN_FILE" ]; then
  echo "Error: chain file not found: $CHAIN_FILE" >&2
  echo "Sign the intermediate CA first so ca-chain.cert.pem exists." >&2
  exit 1
fi

if [ -f "$KEY_FILE" ]; then
  echo "Leaf private key already exists: $KEY_FILE"
else
  echo "Generating leaf private key"
  openssl genpkey \
    -algorithm RSA \
    -out "$KEY_FILE" \
    -pkeyopt rsa_keygen_bits:2048
  chmod 400 "$KEY_FILE"
fi

if [ -f "$CSR_FILE" ]; then
  echo "Leaf CSR already exists: $CSR_FILE"
else
  echo "Generating leaf CSR"
  openssl req \
    -new \
    -sha256 \
    -key "$KEY_FILE" \
    -subj "/O=${ORG}/OU=${OU}/CN=${LEAF_CN}" \
    -out "$CSR_FILE"
  chmod 444 "$CSR_FILE"
fi

echo "Signing leaf CSR"
INTERMEDIATE_CA_OUTPUT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR" DAYS="$DAYS" INTERMEDIATE_CA_CONFIG_FILE="$LEAF_CONFIG_FILE" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sign_leaf_csr.sh" "$CSR_FILE"

cp "$INTERMEDIATE_CA_OUTPUT_DIR/certs/${LEAF_CN}.cert.pem" "$CERT_FILE"
chmod 444 "$CERT_FILE"

echo "Packaging password-protected PKCS#12"
openssl pkcs12 -export \
  -inkey "$KEY_FILE" \
  -in "$CERT_FILE" \
  -certfile "$CHAIN_FILE" \
  -out "$P12_FILE" \
  -passout "pass:$P12_PASSWORD"
chmod 400 "$P12_FILE"

echo
echo "Leaf keypair, certificate and P12 package created successfully."
echo "Private key: $KEY_FILE"
echo "Certificate: $CERT_FILE"
echo "P12 file:    $P12_FILE"
