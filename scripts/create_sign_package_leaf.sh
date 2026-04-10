#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# This script creates/signs/packages a leaf certificate for a profile:
#   server, admin, client
# Example:
#   ./create_sign_package_leaf.sh server api.example.internal 'strong-password'
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}"
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR:-$INTERMEDIATE_CA_OUTPUT_DIR/leaf}"
LEAF_CONFIG_FILE="${LEAF_CONFIG_FILE:-../intermediate_ca/intermediate_ca.cnf}"
DAYS="${DAYS:-825}"
GENERATE_LEAF_CSR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generate_leaf_csr.sh"
SIGN_LEAF_CSR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sign_leaf_csr.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: create_sign_package_leaf.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <server|admin|client> <leaf-common-name> [p12-password]" >&2
  echo "Or set P12_PASSWORD in the environment." >&2
  exit 1
fi

PROFILE="$1"
LEAF_CN="$2"
P12_PASSWORD="${P12_PASSWORD:-}"
EXTRA_CSR_ARGS=()

if [ $# -ge 3 ] && [[ "${3:-}" != --* ]]; then
  P12_PASSWORD="$3"
  shift 3
else
  shift 2
fi

if [ $# -gt 0 ]; then
  EXTRA_CSR_ARGS=("$@")
fi

if [ -z "$P12_PASSWORD" ]; then
  echo "Error: p12 password cannot be empty (arg 3 or P12_PASSWORD env)." >&2
  exit 1
fi

if [[ "$P12_PASSWORD" =~ ^[[:space:]]+$ ]]; then
  echo "Error: p12 password cannot be whitespace-only." >&2
  exit 1
fi

PROFILE_DIR="$LEAF_OUTPUT_DIR/$PROFILE"
PRIVATE_DIR="$PROFILE_DIR/private"
CSR_DIR="$PROFILE_DIR/csr"
CERTS_DIR="$PROFILE_DIR/certs"
EXPORT_DIR="$PROFILE_DIR/export"

# Keep artifacts grouped by profile for operational clarity.
# Example: /opt/pki/intermediate-ca/leaf/server/{private,csr,certs,export}
mkdir -p "$PRIVATE_DIR" "$CSR_DIR" "$CERTS_DIR" "$EXPORT_DIR"

KEY_FILE="$PRIVATE_DIR/${LEAF_CN}.key.pem"
CSR_FILE="$CSR_DIR/${LEAF_CN}.csr.pem"
CERT_FILE="$CERTS_DIR/${LEAF_CN}.cert.pem"
P12_FILE="$EXPORT_DIR/${LEAF_CN}.p12"
CHAIN_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/ca-chain-cert.pem"

if [ ! -f "$LEAF_CONFIG_FILE" ]; then
  echo "Error: OpenSSL intermediate CA config not found: $LEAF_CONFIG_FILE" >&2
  exit 1
fi

if [ ! -f "$CHAIN_FILE" ]; then
  echo "Error: chain file not found: $CHAIN_FILE" >&2
  echo "Sign the intermediate CA first so ca-chain-cert.pem exists." >&2
  exit 1
fi

# Generate (or re-use) key + CSR using the dedicated CSR workflow script.
"$GENERATE_LEAF_CSR_SCRIPT" "$PROFILE" "$LEAF_CN" "${EXTRA_CSR_ARGS[@]}"

# Sign the generated CSR with the intermediate CA.
echo "Signing leaf CSR"
INTERMEDIATE_CA_OUTPUT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR" DAYS="$DAYS" INTERMEDIATE_CA_CONFIG_FILE="$LEAF_CONFIG_FILE" \
  "$SIGN_LEAF_CSR_SCRIPT" "$CSR_FILE"

# Copy the issued cert from the intermediate cert store into the profile folder.
cp "$INTERMEDIATE_CA_OUTPUT_DIR/certs/${LEAF_CN}.cert.pem" "$CERT_FILE"
chmod 444 "$CERT_FILE"

# Build a password-protected PKCS#12 bundle with key + cert + chain.
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
