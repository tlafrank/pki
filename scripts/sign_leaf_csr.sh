#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Signs leaf CSRs with the intermediate CA while enforcing profile/SAN policy.
# Interacts with:
# - scripts/create_intermediate_ca.sh for intermediate-ca.name and CA material.
# - scripts/create_sign_package_leaf.sh, which invokes this script during packaging.
# - intermediate_ca/intermediate_ca.cnf for OpenSSL CA settings.

# --- User-tunable defaults -------------------------------------------------
# This script signs leaf CSRs with the intermediate CA.
# You can override defaults at runtime, for example:
#   INTERMEDIATE_CA_OUTPUT_DIR=/opt/pki/intermediate-ca DAYS=397 ./sign_leaf_csr.sh ./csr/web.csr.pem
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-${SCRIPT_DIR}/../intermediate_ca}"
DAYS="${DAYS:-825}"
ORG="${ORG:-Example Org PKI}"
OU="${OU:-Intermediate CA}"
CN="${CN:-Example Intermediate CA}"
INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE:-${SCRIPT_DIR}/../intermediate_ca/intermediate_ca.cnf}"
NAME_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/intermediate-ca.name"
normalize_ca_name() {
  local value="$1"
  value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(echo "$value" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$value" ]; then
    value="ca-intermediate"
  fi
  if [[ "$value" != ca-* ]]; then
    value="ca-${value}"
  fi
  echo "$value"
}
if [ -z "${INTERMEDIATE_CA_NAME:-}" ] && [ -f "$NAME_FILE" ]; then
  INTERMEDIATE_CA_NAME="$(tr -d '[:space:]' < "$NAME_FILE")"
fi
INTERMEDIATE_CA_NAME="$(normalize_ca_name "${INTERMEDIATE_CA_NAME:-ca-intermediate}")"

# --- Internal paths ---------------------------------------------------------
INTERMEDIATE_CERT_FILE="$INTERMEDIATE_CA_OUTPUT_DIR/certs/${INTERMEDIATE_CA_NAME}.cert.pem"
LEAF_CERTS_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/certs"
LEAF_EXPORT_DIR="$INTERMEDIATE_CA_OUTPUT_DIR/exports"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: sign_leaf_csr.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
fi

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path-to-leaf-csr>" >&2
  exit 1
fi

LEAF_CSR_FILE="$1"

if [ ! -f "$LEAF_CSR_FILE" ]; then
  echo "Error: leaf CSR not found: $LEAF_CSR_FILE" >&2
  exit 1
fi

if [ ! -f "$INTERMEDIATE_CA_CONFIG_FILE" ]; then
  echo "Error: OpenSSL intermediate CA config not found: $INTERMEDIATE_CA_CONFIG_FILE" >&2
  exit 1
fi

if [ ! -f "$INTERMEDIATE_CERT_FILE" ]; then
  echo "Error: intermediate CA certificate not found: $INTERMEDIATE_CERT_FILE" >&2
  echo "Sign the intermediate CA first." >&2
  exit 1
fi

# Export values consumed by $ENV::... references in intermediate_ca.cnf.
export INTERMEDIATE_CA_OUTPUT_DIR DAYS ORG OU CN INTERMEDIATE_CA_NAME

# Ensure expected output directories exist.
mkdir -p "$LEAF_CERTS_DIR" "$LEAF_EXPORT_DIR"

# Convert foo.csr.pem -> foo.cert.pem while preserving basename convention.
CSR_BASENAME="$(basename "$LEAF_CSR_FILE")"
LEAF_CERT_FILE="$LEAF_CERTS_DIR/${CSR_BASENAME/.csr.pem/.cert.pem}"

if [ -f "$LEAF_CERT_FILE" ]; then
  echo "Leaf certificate already exists: $LEAF_CERT_FILE"
else
  # Determine profile from CSR subject OU so signing behavior can enforce
  # profile-specific extension policy.
  CSR_SUBJECT="$(openssl req -in "$LEAF_CSR_FILE" -noout -subject -nameopt RFC2253)"
  CSR_OU="$(echo "$CSR_SUBJECT" | sed -n 's/.*OU=\([^,\/]*\).*/\1/p')"
  case "$CSR_OU" in
    "Server Certificates")
      PROFILE="server"
      EKU="serverAuth"
      ;;
    "Admin Certificates")
      PROFILE="admin"
      EKU="clientAuth"
      ;;
    "Client Certificates")
      PROFILE="client"
      EKU="clientAuth"
      ;;
    *)
      echo "Error: could not determine leaf profile from CSR OU: '${CSR_OU:-<missing>}'." >&2
      echo "Expected OU one of: Server Certificates, Admin Certificates, Client Certificates." >&2
      exit 1
      ;;
  esac

  # Read SAN from CSR (if present).
  SAN_LINE="$(
    openssl req -in "$LEAF_CSR_FILE" -noout -text 2>/dev/null | awk '
      /Subject Alternative Name/ {capture=1; next}
      capture && NF {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        print line
        exit
      }
    '
  )"
  HAS_SAN=0
  if [ -n "$SAN_LINE" ]; then
    HAS_SAN=1
  fi

  # Only server profile certificates may contain SAN.
  if [ "$PROFILE" != "server" ] && [ "$HAS_SAN" -eq 1 ]; then
    echo "Error: CSR for profile '$PROFILE' contains SAN, which is only allowed for server profile." >&2
    exit 1
  fi
  if [ "$PROFILE" = "server" ] && [ "$HAS_SAN" -eq 0 ]; then
    echo "Error: server CSR must contain SAN." >&2
    exit 1
  fi

  TMP_EXTFILE="$(mktemp)"
  if [ "$HAS_SAN" -eq 1 ]; then
    LEAF_SAN="$(echo "$SAN_LINE" | sed 's/IP Address:/IP:/g')"
  fi

  cat > "$TMP_EXTFILE" <<EOF
[leaf_cert]
basicConstraints       = critical, CA:false
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = $EKU
EOF
  if [ "$HAS_SAN" -eq 1 ]; then
    echo "subjectAltName         = $LEAF_SAN" >> "$TMP_EXTFILE"
  fi

  echo "Signing leaf CSR with intermediate CA (profile: $PROFILE)"
  # Use CA policy from config; extensions come from generated leaf_cert profile.
  openssl ca \
    -config "$INTERMEDIATE_CA_CONFIG_FILE" \
    -extfile "$TMP_EXTFILE" \
    -extensions leaf_cert \
    -days "$DAYS" \
    -notext \
    -md sha256 \
    -batch \
    -in "$LEAF_CSR_FILE" \
    -out "$LEAF_CERT_FILE"
  rm -f "$TMP_EXTFILE"
  # Certificates are public material; world-readable is acceptable.
  chmod 444 "$LEAF_CERT_FILE"
fi

# Export a copy with a predictable filename in the exports folder.
cp "$LEAF_CERT_FILE" "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"
chmod 444 "$LEAF_EXPORT_DIR/$(basename "$LEAF_CERT_FILE")"

echo
echo "Leaf certificate created successfully."
echo "Certificate: $LEAF_CERT_FILE"
