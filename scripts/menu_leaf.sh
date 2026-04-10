#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAF_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_leaf_csr.sh"
LEAF_CREATE_SIGN_PACKAGE_SCRIPT="${SCRIPT_DIR}/create_sign_package_leaf.sh"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu_leaf.sh must be run as root." >&2
    echo "Re-run with: sudo $0" >&2
    exit 1
  fi
}

run_script() {
  local script_path="$1"
  shift || true

  if [[ ! -f "$script_path" ]]; then
    echo "Error: expected script not found: $script_path" >&2
    return 1
  fi

  if [[ ! -x "$script_path" ]]; then
    exec bash "$script_path" "$@"
  else
    exec "$script_path" "$@"
  fi
}

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") <action> [args ...]

Actions:
  1 | sign-leaf-csr            Run ${LEAF_SIGN_CSR_SCRIPT##*/} <csr-path>
  2 | create-sign-package-leaf Run ${LEAF_CREATE_SIGN_PACKAGE_SCRIPT##*/} <common-name> <p12-password>
  h | help                     Show this help text
  q | quit                     Exit this menu
EOF
}

interactive_menu() {
  local choice

  while true; do
    cat <<'EOF'
========================================
 Leaf Actions
========================================
1) Sign leaf CSR
2) Create keypair, sign and package leaf certificate
h) Help
q) Back
EOF

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        read -r -p "Path to leaf CSR: " csr_path
        run_script "$LEAF_SIGN_CSR_SCRIPT" "$csr_path"
        ;;
      2)
        read -r -p "Leaf common name: " leaf_cn
        read -r -s -p "P12 password: " p12_password
        echo
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" "$leaf_cn" "$p12_password"
        ;;
      h|H)
        print_usage
        ;;
      q|Q)
        exit 0
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
      1|sign-leaf-csr)
        shift
        run_script "$LEAF_SIGN_CSR_SCRIPT" "$@"
        ;;
      2|create-sign-package-leaf)
        shift
        run_script "$LEAF_CREATE_SIGN_PACKAGE_SCRIPT" "$@"
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
