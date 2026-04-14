#!/usr/bin/env bash
set -euo pipefail

# --- User-tunable defaults -------------------------------------------------
# End-to-end wrapper for leaf certificate lifecycle:
#   1) generate/reuse key + CSR (via generate_leaf_csr.sh)
#   2) sign CSR with intermediate CA (via sign_leaf_csr.sh)
#   3) export key/cert/chain as password-protected PKCS#12 (.p12)
#
# Supported profiles:
#   server, admin, client
#
# SAN handling notes:
# - For server profile, pass SAN values through to generate_leaf_csr.sh using:
#     --san-dns <name> and/or --san-ip <ip>
# - This script forwards all extra args after [p12-password] to CSR generation.
# - Signed certificate SAN presence depends on intermediate CA signing policy,
#   which copies only SAN from CSR while hard-coding other leaf extensions.
#
# Example:
#   ./create_sign_package_leaf.sh server api.example.internal 'strong-password' \
#     --san-dns api.example.internal --san-ip 10.0.0.15
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-${SCRIPT_DIR}/../intermediate_ca}"
LEAF_CONFIG_FILE="${LEAF_CONFIG_FILE:-${SCRIPT_DIR}/../intermediate_ca/intermediate_ca.cnf}"
DAYS="${DAYS:-825}"
DELETE_LEAF_PRIVATE_KEY_AFTER_PACKAGING="${DELETE_LEAF_PRIVATE_KEY_AFTER_PACKAGING:-1}"
CREATE_JKS_OUTPUT="${CREATE_JKS_OUTPUT:-1}"
GENERATE_LEAF_CSR_SCRIPT="${SCRIPT_DIR}/generate_leaf_csr.sh"
SIGN_LEAF_CSR_SCRIPT="${SCRIPT_DIR}/sign_leaf_csr.sh"

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
  echo "Optional trailing args are passed to CSR generation (e.g. --san-dns/--san-ip)." >&2
  echo "Or set P12_PASSWORD in the environment." >&2
  exit 1
fi

PROFILE="$1"
LEAF_CN="$2"
P12_PASSWORD="${P12_PASSWORD:-}"
EXTRA_CSR_ARGS=()

# If positional arg 3 is present and not an option flag, treat it as the p12
# password. Any remaining args are forwarded as CSR-generation options.
if [ $# -ge 3 ] && [[ "${3:-}" != --* ]]; then
  P12_PASSWORD="$3"
  shift 3
else
  # No positional password provided; rely on P12_PASSWORD env var and treat all
  # remaining args as CSR-generation options.
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

INTERMEDIATE_EXPORT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/exports"
INTERMEDIATE_TMP_BASE="$INTERMEDIATE_CA_OUTPUT_DIR/tmp"
INTERMEDIATE_TMP_DIR="$INTERMEDIATE_TMP_BASE/$PROFILE"

# Keep issued certs and p12 bundles under intermediate_ca/{certs,exports}.
mkdir -p "$INTERMEDIATE_EXPORT_DIR" "$INTERMEDIATE_TMP_DIR"

KEY_FILE="$INTERMEDIATE_TMP_DIR/private/${LEAF_CN}.key.pem"
CSR_FILE="$INTERMEDIATE_TMP_DIR/csr/${LEAF_CN}.csr.pem"
CERT_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/${LEAF_CN}.cert.pem"
P12_FILE="$INTERMEDIATE_EXPORT_DIR/${PROFILE}-${LEAF_CN}.p12"
JKS_KEYSTORE_FILE="$INTERMEDIATE_EXPORT_DIR/${PROFILE}-${LEAF_CN}.keystore.jks"
JKS_TRUSTSTORE_FILE="$INTERMEDIATE_EXPORT_DIR/${PROFILE}-${LEAF_CN}.truststore.jks"
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
# EXTRA_CSR_ARGS carries SAN flags for server certificates when supplied.
LEAF_OUTPUT_DIR="$INTERMEDIATE_TMP_BASE" "$GENERATE_LEAF_CSR_SCRIPT" "$PROFILE" "$LEAF_CN" "${EXTRA_CSR_ARGS[@]}"

# Sign the generated CSR with the intermediate CA.
echo "Signing leaf CSR"
INTERMEDIATE_CA_OUTPUT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR" DAYS="$DAYS" INTERMEDIATE_CA_CONFIG_FILE="$LEAF_CONFIG_FILE" \
  "$SIGN_LEAF_CSR_SCRIPT" "$CSR_FILE"

# Build a password-protected PKCS#12 bundle with key + cert + chain.
echo "Packaging password-protected PKCS#12"
openssl pkcs12 -export \
  -inkey "$KEY_FILE" \
  -in "$CERT_FILE" \
  -certfile "$CHAIN_FILE" \
  -out "$P12_FILE" \
  -passout "pass:$P12_PASSWORD"
chmod 400 "$P12_FILE"

if [ "$CREATE_JKS_OUTPUT" = "1" ]; then
  if ! command -v keytool >/dev/null 2>&1; then
    echo "Error: keytool is required to generate JKS outputs." >&2
    echo "Install a Java runtime/JDK or set CREATE_JKS_OUTPUT=0." >&2
    exit 1
  fi

  JKS_PASSWORD="${JKS_PASSWORD:-$P12_PASSWORD}"
  if [ -z "$JKS_PASSWORD" ] || [[ "$JKS_PASSWORD" =~ ^[[:space:]]+$ ]]; then
    echo "Error: JKS password cannot be empty or whitespace-only." >&2
    exit 1
  fi

  rm -f "$JKS_KEYSTORE_FILE" "$JKS_TRUSTSTORE_FILE"

  echo "Generating Java keystore (.jks) from PKCS#12 bundle"
  keytool -importkeystore \
    -srckeystore "$P12_FILE" \
    -srcstoretype PKCS12 \
    -srcstorepass "$P12_PASSWORD" \
    -destkeystore "$JKS_KEYSTORE_FILE" \
    -deststoretype JKS \
    -deststorepass "$JKS_PASSWORD" \
    -destkeypass "$JKS_PASSWORD" \
    -noprompt

  echo "Generating Java truststore (.jks) from CA chain"
  TMP_CHAIN_DIR="$(mktemp -d)"
  csplit -s -z -f "$TMP_CHAIN_DIR/cert-" -b "%02d.pem" "$CHAIN_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}' || true

  cert_index=1
  for cert_file in "$TMP_CHAIN_DIR"/cert-*.pem; do
    [ -f "$cert_file" ] || continue
    if ! grep -q '-----BEGIN CERTIFICATE-----' "$cert_file"; then
      continue
    fi
    keytool -importcert \
      -file "$cert_file" \
      -keystore "$JKS_TRUSTSTORE_FILE" \
      -storetype JKS \
      -storepass "$JKS_PASSWORD" \
      -alias "ca-chain-$cert_index" \
      -noprompt
    cert_index=$((cert_index + 1))
  done
  rm -rf "$TMP_CHAIN_DIR"

  if [ "$cert_index" -eq 1 ]; then
    echo "Error: no certificates were found in chain file: $CHAIN_FILE" >&2
    exit 1
  fi

  chmod 400 "$JKS_KEYSTORE_FILE" "$JKS_TRUSTSTORE_FILE"
fi

# Remove the plaintext private key after successful packaging by default.
if [ "$DELETE_LEAF_PRIVATE_KEY_AFTER_PACKAGING" = "1" ]; then
  if [ -f "$KEY_FILE" ]; then
    chmod 600 "$KEY_FILE" || true
    if command -v shred >/dev/null 2>&1; then
      shred -u "$KEY_FILE"
    else
      rm -f "$KEY_FILE"
    fi
  fi
fi

echo
echo "Leaf keypair, certificate and P12 package created successfully."
if [ "$DELETE_LEAF_PRIVATE_KEY_AFTER_PACKAGING" = "1" ]; then
  echo "Private key deleted after packaging."
else
  echo "Private key: $KEY_FILE"
fi
echo "Certificate: $CERT_FILE"
echo "P12 file:    $P12_FILE"
if [ "$CREATE_JKS_OUTPUT" = "1" ]; then
  echo "JKS keystore:   $JKS_KEYSTORE_FILE"
  echo "JKS truststore: $JKS_TRUSTSTORE_FILE"
fi
