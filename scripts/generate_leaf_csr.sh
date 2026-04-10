#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# This script creates a leaf private key and CSR for one of three profiles:
#   server, admin, client.
# Example:
#   ORG="Example Org PKI" ./generate_leaf_csr.sh server api.example.internal
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}"
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR:-$INTERMEDIATE_CA_OUTPUT_DIR/leaf}"
ORG="${ORG:-Example Org PKI}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: generate_leaf_csr.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

if [ $# -ne 2 ]; then
  echo "Usage: $0 <server|admin|client> <leaf-common-name>" >&2
  exit 1
fi

PROFILE="$1"
LEAF_CN="$2"

# Map the profile to a human-readable OU used in the CSR subject.
case "$PROFILE" in
  server)
    OU="Server Certificates"
    ;;
  admin)
    OU="Admin Certificates"
    ;;
  client)
    OU="Client Certificates"
    ;;
  *)
    echo "Error: unsupported profile '$PROFILE'. Use server, admin or client." >&2
    exit 1
    ;;
esac

# Keep profile artifacts separated for easier lifecycle/rotation management.
PROFILE_DIR="$LEAF_OUTPUT_DIR/$PROFILE"
PRIVATE_DIR="$PROFILE_DIR/private"
CSR_DIR="$PROFILE_DIR/csr"

KEY_FILE="$PRIVATE_DIR/${LEAF_CN}.key.pem"
CSR_FILE="$CSR_DIR/${LEAF_CN}.csr.pem"

mkdir -p "$PRIVATE_DIR" "$CSR_DIR"

# Generate the private key once and re-use it if it already exists.
if [ -f "$KEY_FILE" ]; then
  echo "Leaf private key already exists: $KEY_FILE"
else
  echo "Generating $PROFILE leaf private key"
  openssl genpkey \
    -algorithm RSA \
    -out "$KEY_FILE" \
    -pkeyopt rsa_keygen_bits:2048
  chmod 400 "$KEY_FILE"
fi

# Generate the CSR once and re-use it if it already exists.
if [ -f "$CSR_FILE" ]; then
  echo "Leaf CSR already exists: $CSR_FILE"
else
  echo "Generating $PROFILE leaf CSR"
  openssl req \
    -new \
    -sha256 \
    -key "$KEY_FILE" \
    -subj "/O=${ORG}/OU=${OU}/CN=${LEAF_CN}" \
    -out "$CSR_FILE"
  chmod 444 "$CSR_FILE"
fi

echo
echo "Leaf CSR workflow completed."
echo "Profile:     $PROFILE"
echo "Private key: $KEY_FILE"
echo "CSR:         $CSR_FILE"
