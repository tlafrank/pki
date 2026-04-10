#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Intermediate CA submenu owns tasks performed by the intermediate tier:
# - bootstrap intermediate CA key+CSR
# - issue leaf credentials and package PKCS#12 bundles
# - optionally sign externally provided leaf CSRs
INTERMEDIATE_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_intermediate_ca.sh"
LEAF_CREATE_SIGN_PACKAGE_SCRIPT="${SCRIPT_DIR}/create_sign_package_leaf.sh"
LEAF_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_leaf_csr.sh"

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
  local chain_file="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}/certs/ca-chain-cert.pem"
  if [[ ! -f "$chain_file" ]]; then
    echo "Error: chain file not found: $chain_file" >&2
    echo "Sign the intermediate CA first so ca-chain-cert.pem exists." >&2
    return 1
  fi
}

require_intermediate_certificate() {
  local intermediate_cert="${INTERMEDIATE_CA_OUTPUT_DIR:-/opt/pki/intermediate-ca}/certs/intermediate-ca.cert.pem"
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
        read -r -p "Server common name: " leaf_cn
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" server "$leaf_cn" "$p12_password"
        ;;
      3)
        require_intermediate_certificate || continue
        require_chain_file || continue
        read -r -p "Admin common name: " leaf_cn
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" admin "$leaf_cn" "$p12_password"
        ;;
      4)
        require_intermediate_certificate || continue
        require_chain_file || continue
        read -r -p "Client common name: " leaf_cn
        p12_password="$(read_p12_password 'P12 password: ')"
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" client "$leaf_cn" "$p12_password"
        ;;
      5)
        require_intermediate_certificate || continue
        read -r -p "Path to leaf CSR: " csr_path
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
