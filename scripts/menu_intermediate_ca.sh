#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERMEDIATE_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_intermediate_ca.sh"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu_intermediate_ca.sh must be run as root." >&2
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
  1 | create-intermediate-ca   Run ${INTERMEDIATE_CA_CREATE_SCRIPT##*/}
  h | help                     Show this help text
  q | quit                     Exit this menu
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
h) Help
q) Back
EOF

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        run_script "$INTERMEDIATE_CA_CREATE_SCRIPT"
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
      1|create-intermediate-ca)
        shift
        run_script "$INTERMEDIATE_CA_CREATE_SCRIPT" "$@"
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
