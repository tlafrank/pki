#!/usr/bin/env bash
set -euo pipefail

# --- Root CA location and defaults ------------------------------------------
# Allow override, but default to the expected root CA location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-${SCRIPT_DIR}/../root_ca}"
DAYS="${DAYS:-3650}"
# These are only needed so root_ca.cnf can resolve $ENV::... variables in all
# sections when OpenSSL parses the config for `openssl ca`.
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Root CA}"
CN="${CN:-Example Root CA}"
CREATE_JKS_TRUSTSTORE="${CREATE_JKS_TRUSTSTORE:-1}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-${JKS_PASSWORD:-changeit}}"

ROOT_CERT_FILE="$ROOT_CA_OUTPUT_DIR/certs/root-ca.cert.pem"

# Check that the script is being run as root.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: sign_intermediate_csr.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
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

INTERMEDIATE_CA_NAME="${INTERMEDIATE_CA_NAME:-$(basename "$INTERMEDIATE_CSR_FILE" .csr.pem)}"

if [ ! -f "$INTERMEDIATE_CSR_FILE" ]; then
  echo "Error: intermediate CA CSR not found: $INTERMEDIATE_CSR_FILE" >&2
  exit 1
fi

# Resolve output locations under the fixed root CA directory structure.
CERTS_DIR="$ROOT_CA_OUTPUT_DIR/certs"
EXPORT_DIR="$ROOT_CA_OUTPUT_DIR/exports"
INTERMEDIATE_CERT_FILE="$CERTS_DIR/${INTERMEDIATE_CA_NAME}.cert.pem"
CHAIN_FILE="$CERTS_DIR/${INTERMEDIATE_CA_NAME}-chain.cert.pem"
TRUSTSTORE_JKS_FILE="$EXPORT_DIR/${INTERMEDIATE_CA_NAME}.truststore.jks"

# Resolve the root CA OpenSSL config using a list of likely paths.
if [ -n "${ROOT_CA_CONFIG_FILE:-}" ]; then
  RESOLVED_ROOT_CA_CONFIG_FILE="$ROOT_CA_CONFIG_FILE"
else
  CANDIDATE_CONFIG_FILES=(
    "$ROOT_CA_OUTPUT_DIR/root_ca.cnf"
    "$ROOT_CA_OUTPUT_DIR/root-ca.cnf"
    "${SCRIPT_DIR}/../root_ca/root_ca.cnf"
    "${SCRIPT_DIR}/../root_ca/root-ca.cnf"
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
  echo "  ${SCRIPT_DIR}/../root_ca/root_ca.cnf" >&2
  echo "  ${SCRIPT_DIR}/../root_ca/root-ca.cnf" >&2
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

# Export copies for downstream tooling.
# Keep a filename that matches what intermediate_ca expects so operators can
# copy directly from root_ca/exports/ into intermediate_ca/certs/.
cp "$INTERMEDIATE_CERT_FILE" "$EXPORT_DIR/${INTERMEDIATE_CA_NAME}.cert.pem"
cp "$CHAIN_FILE" "$EXPORT_DIR/${INTERMEDIATE_CA_NAME}-chain.cert.pem"
chmod 444 \
  "$EXPORT_DIR/${INTERMEDIATE_CA_NAME}.cert.pem" \
  "$EXPORT_DIR/${INTERMEDIATE_CA_NAME}-chain.cert.pem"

if [ "$CREATE_JKS_TRUSTSTORE" = "1" ]; then
  if ! command -v keytool >/dev/null 2>&1; then
    echo "Error: keytool is required to generate JKS truststore output." >&2
    echo "Install a Java runtime/JDK or set CREATE_JKS_TRUSTSTORE=0." >&2
    exit 1
  fi

  if [ -z "$TRUSTSTORE_PASSWORD" ] || [[ "$TRUSTSTORE_PASSWORD" =~ ^[[:space:]]+$ ]]; then
    echo "Error: TRUSTSTORE_PASSWORD cannot be empty or whitespace-only." >&2
    exit 1
  fi

  echo "Generating Java truststore (.jks) from CA chain"
  rm -f "$TRUSTSTORE_JKS_FILE"

  TMP_CHAIN_DIR="$(mktemp -d)"
  csplit -s -z -f "$TMP_CHAIN_DIR/cert-" -b "%02d.pem" "$CHAIN_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}' || true

  cert_index=1
  for cert_file in "$TMP_CHAIN_DIR"/cert-*.pem; do
    [ -f "$cert_file" ] || continue
    if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$cert_file"; then
      continue
    fi
    keytool -importcert \
      -file "$cert_file" \
      -keystore "$TRUSTSTORE_JKS_FILE" \
      -storetype JKS \
      -storepass "$TRUSTSTORE_PASSWORD" \
      -alias "ca-chain-$cert_index" \
      -noprompt
    cert_index=$((cert_index + 1))
  done
  rm -rf "$TMP_CHAIN_DIR"

  if [ "$cert_index" -eq 1 ]; then
    echo "Error: no certificates were found in chain file: $CHAIN_FILE" >&2
    exit 1
  fi

  chmod 400 "$TRUSTSTORE_JKS_FILE"
fi

if [ "$CREATE_JKS_TRUSTSTORE" = "1" ]; then
  if ! command -v keytool >/dev/null 2>&1; then
    echo "Error: keytool is required to generate JKS truststore output." >&2
    echo "Install a Java runtime/JDK or set CREATE_JKS_TRUSTSTORE=0." >&2
    exit 1
  fi

  if [ -z "$TRUSTSTORE_PASSWORD" ] || [[ "$TRUSTSTORE_PASSWORD" =~ ^[[:space:]]+$ ]]; then
    echo "Error: TRUSTSTORE_PASSWORD cannot be empty or whitespace-only." >&2
    exit 1
  fi

  echo "Generating Java truststore (.jks) from CA chain"
  rm -f "$TRUSTSTORE_JKS_FILE"

  TMP_CHAIN_DIR="$(mktemp -d)"
  csplit -s -z -f "$TMP_CHAIN_DIR/cert-" -b "%02d.pem" "$CHAIN_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}' || true

  cert_index=1
  for cert_file in "$TMP_CHAIN_DIR"/cert-*.pem; do
    [ -f "$cert_file" ] || continue
    if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$cert_file"; then
      continue
    fi
    keytool -importcert \
      -file "$cert_file" \
      -keystore "$TRUSTSTORE_JKS_FILE" \
      -storetype JKS \
      -storepass "$TRUSTSTORE_PASSWORD" \
      -alias "ca-chain-$cert_index" \
      -noprompt
    cert_index=$((cert_index + 1))
  done
  rm -rf "$TMP_CHAIN_DIR"

  if [ "$cert_index" -eq 1 ]; then
    echo "Error: no certificates were found in chain file: $CHAIN_FILE" >&2
    exit 1
  fi

  chmod 400 "$TRUSTSTORE_JKS_FILE"
fi

echo

echo "Intermediate CA certificate created successfully."
echo "Intermediate cert: $INTERMEDIATE_CERT_FILE"
echo "Chain file:        $CHAIN_FILE"
echo "Exports:"
echo "  $EXPORT_DIR/${INTERMEDIATE_CA_NAME}.cert.pem"
echo "  $EXPORT_DIR/${INTERMEDIATE_CA_NAME}-chain.cert.pem"
if [ "$CREATE_JKS_TRUSTSTORE" = "1" ]; then
  echo "  $TRUSTSTORE_JKS_FILE"
fi
echo
echo "Inspect created certificate with:"
echo "  openssl x509 -in $INTERMEDIATE_CERT_FILE -noout -text"
