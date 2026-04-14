#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Leaf-only submenu wrapper for generating server/admin/client CSRs.
# Interacts with:
# - scripts/generate_leaf_csr.sh for all menu actions.
# - scripts/menu.sh when used as a submenu.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Leaf submenu is intentionally CSR-focused only.
# Signing and packaging actions are performed in the intermediate menu.
GENERATE_LEAF_CSR_SCRIPT="${SCRIPT_DIR}/generate_leaf_csr.sh"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu_leaf.sh must be run as root." >&2
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

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") <action> [args ...]

Actions:
  1 | generate-server-csr      Run ${GENERATE_LEAF_CSR_SCRIPT##*/} server <common-name>
  2 | generate-admin-csr       Run ${GENERATE_LEAF_CSR_SCRIPT##*/} admin <common-name>
  3 | generate-client-csr      Run ${GENERATE_LEAF_CSR_SCRIPT##*/} client <common-name>
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
 Leaf Actions
========================================
1) Generate server CSR
2) Generate admin CSR
3) Generate client CSR
h) Help
q) Quit
EOF
    if [[ "${FROM_MAIN_MENU:-0}" == "1" ]]; then
      echo "b) Back to main menu"
    fi

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        read -r -p "Server common name: " leaf_cn
        run_script "$GENERATE_LEAF_CSR_SCRIPT" server "$leaf_cn"
        ;;
      2)
        read -r -p "Admin common name: " leaf_cn
        run_script "$GENERATE_LEAF_CSR_SCRIPT" admin "$leaf_cn"
        ;;
      3)
        read -r -p "Client common name: " leaf_cn
        run_script "$GENERATE_LEAF_CSR_SCRIPT" client "$leaf_cn"
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
      1|generate-server-csr)
        shift
        run_script "$GENERATE_LEAF_CSR_SCRIPT" server "$@"
        ;;
      2|generate-admin-csr)
        shift
        run_script "$GENERATE_LEAF_CSR_SCRIPT" admin "$@"
        ;;
      3|generate-client-csr)
        shift
        run_script "$GENERATE_LEAF_CSR_SCRIPT" client "$@"
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
