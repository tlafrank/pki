#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Intermediate-CA submenu wrapper for creating intermediate CA state and issuing leaf artifacts.
# Interacts with:
# - scripts/create_intermediate_ca.sh
# - scripts/create_sign_package_leaf.sh
# - scripts/sign_leaf_csr.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INTERMEDIATE_CA_OUTPUT_DIR="${DEFAULT_PKI_BASE_DIR:-/opt/pki}/intermediate-ca"
# Intermediate CA submenu owns tasks performed by the intermediate tier:
# - bootstrap intermediate CA key+CSR
# - issue leaf credentials and package PKCS#12 bundles
# - optionally sign externally provided leaf CSRs
INTERMEDIATE_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_intermediate_ca.sh"
LEAF_CREATE_SIGN_PACKAGE_SCRIPT="${SCRIPT_DIR}/create_sign_package_leaf.sh"
LEAF_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_leaf_csr.sh"

set_default_intermediate_ca_env() {
  export INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-$DEFAULT_INTERMEDIATE_CA_OUTPUT_DIR}"

  if [[ -z "${INTERMEDIATE_CA_CONFIG_FILE:-}" ]]; then
    if [[ -f "${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate_ca.cnf" ]]; then
      export INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate_ca.cnf"
    elif [[ -f "${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate-ca.cnf" ]]; then
      export INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate-ca.cnf"
    elif [[ -f "${SCRIPT_DIR}/../intermediate_ca/intermediate_ca.cnf" ]]; then
      export INTERMEDIATE_CA_CONFIG_FILE="${SCRIPT_DIR}/../intermediate_ca/intermediate_ca.cnf"
    elif [[ -f "${SCRIPT_DIR}/../intermediate_ca/intermediate-ca.cnf" ]]; then
      export INTERMEDIATE_CA_CONFIG_FILE="${SCRIPT_DIR}/../intermediate_ca/intermediate-ca.cnf"
    fi
  fi

  export LEAF_CONFIG_FILE="${LEAF_CONFIG_FILE:-${INTERMEDIATE_CA_CONFIG_FILE:-}}"
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local user_value

  read -r -e -p "$prompt [$default_value]: " user_value
  if [[ -z "$user_value" ]]; then
    user_value="$default_value"
  fi
  printf '%s' "$user_value"
}

resolve_intermediate_ca_name() {
  local intermediate_dir="${INTERMEDIATE_CA_OUTPUT_DIR:-$DEFAULT_INTERMEDIATE_CA_OUTPUT_DIR}"
  local name_file="$intermediate_dir/intermediate-ca.name"
  local raw_name
  if [[ -f "$name_file" ]]; then
    raw_name="$(tr -d '[:space:]' < "$name_file")"
  else
    raw_name="ca-intermediate"
  fi

  raw_name="$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$raw_name" ]]; then
    raw_name="ca-intermediate"
  fi
  if [[ "$raw_name" != ca-* ]]; then
    raw_name="ca-${raw_name}"
  fi
  echo "$raw_name"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu_intermediate_ca.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    exit 1
  fi
}

run_script() {
  # Consistent launcher used by all menu actions.
  local script_path="$1"
  shift || true

  if [[ ! -f "$script_path" ]]; then
    echo "Error: expected script not found: $script_path" >&2
    return 1
  fi

  if [[ ! -x "$script_path" ]]; then
    bash "$script_path" "$@"
  else
    "$script_path" "$@"
  fi
}

require_chain_file() {
  local intermediate_name
  intermediate_name="$(resolve_intermediate_ca_name)"
  local chain_file="${INTERMEDIATE_CA_OUTPUT_DIR:-$DEFAULT_INTERMEDIATE_CA_OUTPUT_DIR}/certs/${intermediate_name}.chain.cert.pem"
  if [[ ! -f "$chain_file" ]]; then
    echo "Error: chain file not found: $chain_file" >&2
    echo "Sign the intermediate CA first so the chain file exists." >&2
    return 1
  fi
}

require_intermediate_certificate() {
  local intermediate_name
  intermediate_name="$(resolve_intermediate_ca_name)"
  local intermediate_cert="${INTERMEDIATE_CA_OUTPUT_DIR:-$DEFAULT_INTERMEDIATE_CA_OUTPUT_DIR}/certs/${intermediate_name}.cert.pem"
  if [[ ! -f "$intermediate_cert" ]]; then
    echo "Error: intermediate CA certificate not found: $intermediate_cert" >&2
    echo "Sign the intermediate CA first." >&2
    return 1
  fi
}

read_p12_password() {
  local prompt="$1"
  local p12_password

  while true; do
    read -r -s -p "$prompt" p12_password
    echo
    if [[ -n "$p12_password" && ! "$p12_password" =~ ^[[:space:]]+$ ]]; then
      printf '%s' "$p12_password"
      return 0
    fi
    echo "Error: p12 password cannot be empty or whitespace-only." >&2
  done
}

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") <action> [args ...]

Actions:
  1 | create-intermediate-ca   Run ${INTERMEDIATE_CA_CREATE_SCRIPT##*/}
  2 | generate-server-p12      Run ${LEAF_CREATE_SIGN_PACKAGE_SCRIPT##*/} server <common-name> <p12-password>
  3 | generate-admin-p12       Run ${LEAF_CREATE_SIGN_PACKAGE_SCRIPT##*/} admin <common-name> <p12-password>
  4 | generate-client-p12      Run ${LEAF_CREATE_SIGN_PACKAGE_SCRIPT##*/} client <common-name> <p12-password>
  5 | sign-leaf-csr            Run ${LEAF_SIGN_CSR_SCRIPT##*/} <csr-path>
  h | help                     Show this help text
  q | quit                     Exit this menu
  b | back                     Return to main menu (only when called from menu.sh)
EOF
}

interactive_menu() {
  local choice

  while true; do
    cat <<'EOF'
========================================
 Intermediate CA Actions
========================================
1) Create intermediate CA keypair and CSR
2) Generate server key/cert as password-protected P12
3) Generate admin key/cert as password-protected P12
4) Generate client key/cert as password-protected P12
5) Sign leaf CSR
h) Help
q) Quit
EOF
    if [[ "${FROM_MAIN_MENU:-0}" == "1" ]]; then
      echo "b) Back to main menu"
    fi

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        run_script "$INTERMEDIATE_CA_CREATE_SCRIPT"
        ;;
      2)
        require_intermediate_certificate || continue
        require_chain_file || continue
        leaf_cn="$(prompt_with_default "Server common name" "server.example.internal")"
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" server "$leaf_cn" "$p12_password"
        ;;
      3)
        require_intermediate_certificate || continue
        require_chain_file || continue
        leaf_cn="$(prompt_with_default "Admin common name" "admin@example.org")"
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" admin "$leaf_cn" "$p12_password"
        ;;
      4)
        require_intermediate_certificate || continue
        require_chain_file || continue
        leaf_cn="$(prompt_with_default "Client common name" "client@example.org")"
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" client "$leaf_cn" "$p12_password"
        ;;
      5)
        require_intermediate_certificate || continue
        csr_path="$(prompt_with_default "Path to leaf CSR" "${LEAF_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR:-/opt/pki}/leaf}/server/csr/server.example.internal.csr.pem")"
        run_script "$LEAF_SIGN_CSR_SCRIPT" "$csr_path"
        ;;
      h|H)
        print_usage
        ;;
      q|Q)
        # When invoked from menu.sh, 99 signals a full quit request.
        if [[ "${FROM_MAIN_MENU:-0}" == "1" ]]; then
          exit 99
        fi
        exit 0
        ;;
      b|B|back)
        if [[ "${FROM_MAIN_MENU:-0}" == "1" ]]; then
          return 0
        fi
        echo "Back is only available when called from menu.sh." >&2
        ;;
      *)
        echo "Invalid selection: $choice" >&2
        ;;
    esac
  done
}

main() {
  require_root
  set_default_intermediate_ca_env

  if [[ $# -gt 0 ]]; then
    case "$1" in
      1|create-intermediate-ca)
        shift
        run_script "$INTERMEDIATE_CA_CREATE_SCRIPT" "$@"
        ;;
      2|generate-server-p12)
        shift
        require_intermediate_certificate || exit 1
        require_chain_file || exit 1
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" =~ ^[[:space:]]+$ ]]; then
          echo "Usage: $(basename "$0") generate-server-p12 <common-name> <p12-password>" >&2
          exit 1
        fi
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" server "$@"
        ;;
      3|generate-admin-p12)
        shift
        require_intermediate_certificate || exit 1
        require_chain_file || exit 1
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" =~ ^[[:space:]]+$ ]]; then
          echo "Usage: $(basename "$0") generate-admin-p12 <common-name> <p12-password>" >&2
          exit 1
        fi
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" admin "$@"
        ;;
      4|generate-client-p12)
        shift
        require_intermediate_certificate || exit 1
        require_chain_file || exit 1
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" =~ ^[[:space:]]+$ ]]; then
          echo "Usage: $(basename "$0") generate-client-p12 <common-name> <p12-password>" >&2
          exit 1
        fi
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" client "$@"
        ;;
      5|sign-leaf-csr)
        shift
        require_intermediate_certificate || exit 1
        run_script "$LEAF_SIGN_CSR_SCRIPT" "$@"
        ;;
      h|help|-h|--help)
        print_usage
        ;;
      q|quit|exit)
        exit 0
        ;;
      *)
        echo "Error: unknown action: $1" >&2
        print_usage >&2
        exit 1
        ;;
    esac
  else
    interactive_menu
  fi
}

main "$@"
