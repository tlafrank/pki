#!/usr/bin/env bash
set -euo pipefail

# --- Root CA location and defaults ------------------------------------------
# Allow override, but default to the expected root CA location.
ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-/opt/pki/root_ca}"
DAYS="${DAYS:-3650}"
# These are only needed so root_ca.cnf can resolve $ENV::... variables in all
# sections when OpenSSL parses the config for `openssl ca`.
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Root CA}"
CN="${CN:-Example Root CA}"

ROOT_CERT_FILE="$ROOT_CA_OUTPUT_DIR/certs/root-ca.cert.pem"

# Check that the script is being run as root.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: sign_intermediate_csr.sh must be run as root." >&2
  echo "Re-run with: sudo $0" >&2
  exit 1
fi

# If no argument is supplied, prompt with readline support so operators can
# use tab completion for path navigation.
if [ $# -eq 0 ]; then
  read -r -e -p "Path to intermediate CSR: " INTERMEDIATE_CSR_FILE
elif [ $# -eq 1 ]; then
  INTERMEDIATE_CSR_FILE="$1"
else
  echo "Usage: $0 <path-to-intermediate-csr>" >&2
  exit 1
fi

if [ ! -f "$INTERMEDIATE_CSR_FILE" ]; then
  echo "Error: intermediate CA CSR not found: $INTERMEDIATE_CSR_FILE" >&2
  exit 1
fi

# Resolve output locations under the fixed root CA directory structure.
CERTS_DIR="$ROOT_CA_OUTPUT_DIR/certs"
EXPORT_DIR="$ROOT_CA_OUTPUT_DIR/exports"
INTERMEDIATE_CERT_FILE="$CERTS_DIR/intermediate-ca.cert.pem"
CHAIN_FILE="$CERTS_DIR/ca-chain-cert.pem"

# Resolve the root CA OpenSSL config using a list of likely paths.
if [ -n "${ROOT_CA_CONFIG_FILE:-}" ]; then
  RESOLVED_ROOT_CA_CONFIG_FILE="$ROOT_CA_CONFIG_FILE"
else
  CANDIDATE_CONFIG_FILES=(
    "$ROOT_CA_OUTPUT_DIR/root_ca.cnf"
    "$ROOT_CA_OUTPUT_DIR/root-ca.cnf"
    "../root_ca/root_ca.cnf"
    "../root_ca/root-ca.cnf"
  )

  RESOLVED_ROOT_CA_CONFIG_FILE=""
  for candidate in "${CANDIDATE_CONFIG_FILES[@]}"; do
    if [ -f "$candidate" ]; then
      RESOLVED_ROOT_CA_CONFIG_FILE="$candidate"
      break
    fi
  done
fi

if [ -z "${RESOLVED_ROOT_CA_CONFIG_FILE:-}" ] || [ ! -f "$RESOLVED_ROOT_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL root CA config not found." >&2
  echo "Checked:" >&2
  echo "  $ROOT_CA_OUTPUT_DIR/root_ca.cnf" >&2
  echo "  $ROOT_CA_OUTPUT_DIR/root-ca.cnf" >&2
  echo "  ../root_ca/root_ca.cnf" >&2
  echo "  ../root_ca/root-ca.cnf" >&2
  echo "Set ROOT_CA_CONFIG_FILE explicitly and re-run." >&2
  exit 1
fi

# Check prerequisite root CA artifacts.
if [ ! -f "$ROOT_CERT_FILE" ]; then
  ALT_ROOT_CA_OUTPUT_DIR="/opt/pki/root-ca"
  ALT_ROOT_CERT_FILE="$ALT_ROOT_CA_OUTPUT_DIR/certs/root-ca.cert.pem"
  if [ -f "$ALT_ROOT_CERT_FILE" ]; then
    ROOT_CA_OUTPUT_DIR="$ALT_ROOT_CA_OUTPUT_DIR"
    ROOT_CERT_FILE="$ALT_ROOT_CERT_FILE"
  else
    echo "Error: root CA certificate not found: $ROOT_CERT_FILE" >&2
    echo "Run create_root_ca.sh first (or set ROOT_CA_OUTPUT_DIR)." >&2
    exit 1
  fi
fi

# Export values consumed by $ENV::... references in the root CA config.
export ROOT_CA_OUTPUT_DIR DAYS ORG OU CN

# Ensure output folders exist.
mkdir -p "$CERTS_DIR" "$EXPORT_DIR"

# Sign the intermediate CSR with the root CA key/certificate.
if [ -f "$INTERMEDIATE_CERT_FILE" ]; then
  echo "Intermediate CA certificate already exists: $INTERMEDIATE_CERT_FILE"
else
  echo "Signing intermediate CA CSR with root CA"
  # Use the root CA policy and v3_intermediate_ca extension set from root_ca.cnf.
  openssl ca \
    -config "$RESOLVED_ROOT_CA_CONFIG_FILE" \
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

# Export copy for downstream tooling.
# Keep a filename that matches what intermediate_ca expects so operators can
# copy directly from root_ca/exports/ into intermediate_ca/certs/.
cp "$INTERMEDIATE_CERT_FILE" "$EXPORT_DIR/intermediate-ca.cert.pem"
cp "$CHAIN_FILE" "$EXPORT_DIR/ca-chain-cert.pem"
chmod 444 \
  "$EXPORT_DIR/intermediate-ca.cert.pem" \
  "$EXPORT_DIR/ca-chain-cert.pem"

echo

echo "Intermediate CA certificate created successfully."
echo "Intermediate cert: $INTERMEDIATE_CERT_FILE"
echo "Chain file:        $CHAIN_FILE"
echo "Exports:"
echo "  $EXPORT_DIR/intermediate-ca.cert.pem"
echo "  $EXPORT_DIR/ca-chain-cert.pem"
echo
echo "Inspect created certificate with:"
echo "  openssl x509 -in $INTERMEDIATE_CERT_FILE -noout -text"
