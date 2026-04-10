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
  if [ "${ALLOW_NON_ROOT:-0}" != "1" ]; then
    echo "Error: generate_leaf_csr.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    echo "For automation/workers, set ALLOW_NON_ROOT=1 and writable output dirs." >&2
    exit 1
  fi
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <server|admin|client> <leaf-common-name> [--san-dns <name>]... [--san-ip <ip>]..." >&2
  exit 1
fi

PROFILE="$1"
LEAF_CN="$2"
shift 2

SAN_DNS_ENTRIES=()
SAN_IP_ENTRIES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --san-dns)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --san-dns requires a non-empty value." >&2
        exit 1
      fi
      SAN_DNS_ENTRIES+=("$2")
      shift 2
      ;;
    --san-ip)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --san-ip requires a non-empty value." >&2
        exit 1
      fi
      SAN_IP_ENTRIES+=("$2")
      shift 2
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

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

  if [ "$PROFILE" = "server" ]; then
    if [ "${#SAN_DNS_ENTRIES[@]}" -eq 0 ] && [ -n "${SAN_DNS_LIST:-}" ]; then
      IFS=',' read -r -a SAN_DNS_ENTRIES <<< "$SAN_DNS_LIST"
    fi

    if [ "${#SAN_IP_ENTRIES[@]}" -eq 0 ] && [ -n "${SAN_IP_LIST:-}" ]; then
      IFS=',' read -r -a SAN_IP_ENTRIES <<< "$SAN_IP_LIST"
    fi

    if [ "${#SAN_DNS_ENTRIES[@]}" -eq 0 ] && [ "${#SAN_IP_ENTRIES[@]}" -eq 0 ]; then
      if [ -t 0 ]; then
        echo "Collect SAN DNS entries for server certificate (press Enter on empty line to finish):"
        while true; do
          read -r -p "  DNS SAN: " dns_entry
          if [ -z "$dns_entry" ]; then
            break
          fi
          SAN_DNS_ENTRIES+=("$dns_entry")
        done

        echo "Collect SAN IP entries for server certificate (press Enter on empty line to finish):"
        while true; do
          read -r -p "  IP SAN: " ip_entry
          if [ -z "$ip_entry" ]; then
            break
          fi
          SAN_IP_ENTRIES+=("$ip_entry")
        done
      else
        echo "Error: server profile requires SAN values in non-interactive mode." >&2
        echo "Provide --san-dns/--san-ip flags or SAN_DNS_LIST/SAN_IP_LIST env vars." >&2
        exit 1
      fi
    fi

    if [ "${#SAN_DNS_ENTRIES[@]}" -eq 0 ] && [ "${#SAN_IP_ENTRIES[@]}" -eq 0 ]; then
      echo "Error: at least one SAN entry (DNS or IP) is required for server certificates." >&2
      exit 1
    fi

    # Build a temporary OpenSSL req config with SAN extensions.
    TMP_SAN_CONFIG="$(mktemp)"
    {
      echo "[ req ]"
      echo "distinguished_name = dn"
      echo "prompt = no"
      echo "req_extensions = v3_req"
      echo
      echo "[ dn ]"
      echo "O = $ORG"
      echo "OU = $OU"
      echo "CN = $LEAF_CN"
      echo
      echo "[ v3_req ]"
      echo "subjectAltName = @alt_names"
      echo
      echo "[ alt_names ]"

      san_index=1
      for dns in "${SAN_DNS_ENTRIES[@]}"; do
        echo "DNS.$san_index = $dns"
        san_index=$((san_index + 1))
      done

      san_index=1
      for ip in "${SAN_IP_ENTRIES[@]}"; do
        echo "IP.$san_index = $ip"
        san_index=$((san_index + 1))
      done
    } > "$TMP_SAN_CONFIG"

    openssl req \
      -new \
      -sha256 \
      -key "$KEY_FILE" \
      -config "$TMP_SAN_CONFIG" \
      -out "$CSR_FILE"

    rm -f "$TMP_SAN_CONFIG"
  else
    openssl req \
      -new \
      -sha256 \
      -key "$KEY_FILE" \
      -subj "/O=${ORG}/OU=${OU}/CN=${LEAF_CN}" \
      -out "$CSR_FILE"
  fi

  chmod 444 "$CSR_FILE"
fi

echo
echo "Leaf CSR workflow completed."
echo "Profile:     $PROFILE"
echo "Private key: $KEY_FILE"
echo "CSR:         $CSR_FILE"
