#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_root_ca.sh"
INTERMEDIATE_CA_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_intermediate_csr.sh"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu_root_ca.sh must be run as root." >&2
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
  1 | create-root-ca           Run ${ROOT_CA_CREATE_SCRIPT##*/}
  2 | sign-intermediate-csr    Run ${INTERMEDIATE_CA_SIGN_CSR_SCRIPT##*/} <csr-path>
  h | help                     Show this help text
  q | quit                     Exit this menu
EOF
}

interactive_menu() {
  local choice

  while true; do
    cat <<'EOF'
========================================
 Root CA Actions
========================================
1) Create root CA keypair and certificate
2) Sign intermediate CA CSR
h) Help
q) Back
EOF

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        run_script "$ROOT_CA_CREATE_SCRIPT"
        ;;
      2)
        read -r -p "Path to intermediate CSR: " csr_path
        run_script "$INTERMEDIATE_CA_SIGN_CSR_SCRIPT" "$csr_path"
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
      1|create-root-ca)
        shift
        run_script "$ROOT_CA_CREATE_SCRIPT" "$@"
        ;;
      2|sign-intermediate-csr)
        shift
        run_script "$INTERMEDIATE_CA_SIGN_CSR_SCRIPT" "$@"
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
