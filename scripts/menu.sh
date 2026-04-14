#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Top-level interactive/CLI menu entrypoint for PKI workflows.
# Interacts with:
# - scripts/menu_root_ca.sh
# - scripts/menu_intermediate_ca.sh
# - scripts/menu_leaf.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_MENU_SCRIPT="${SCRIPT_DIR}/menu_root_ca.sh"
INTERMEDIATE_MENU_SCRIPT="${SCRIPT_DIR}/menu_intermediate_ca.sh"
LEAF_MENU_SCRIPT="${SCRIPT_DIR}/menu_leaf.sh"
DEFAULT_PKI_BASE_DIR="${DEFAULT_PKI_BASE_DIR:-/opt/pki}"

resolve_file_from_candidates() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

set_default_output_dirs() {
  # Keep menu-driven workflows out of the git checkout by default.
  export ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR}/root-ca}"
  export INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR}/intermediate-ca}"
  export LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR}/leaf}"
}

set_default_config_files() {
  local resolved_root_config=""
  local resolved_intermediate_config=""

  if [[ -z "${ROOT_CA_CONFIG_FILE:-}" ]]; then
    resolved_root_config="$(
      resolve_file_from_candidates \
        "${ROOT_CA_OUTPUT_DIR}/root_ca.cnf" \
        "${ROOT_CA_OUTPUT_DIR}/root-ca.cnf" \
        "${SCRIPT_DIR}/../root_ca/root_ca.cnf" \
        "${SCRIPT_DIR}/../root_ca/root-ca.cnf" || true
    )"
    if [[ -n "$resolved_root_config" ]]; then
      export ROOT_CA_CONFIG_FILE="$resolved_root_config"
    fi
  fi

  if [[ -z "${INTERMEDIATE_CA_CONFIG_FILE:-}" ]]; then
    resolved_intermediate_config="$(
      resolve_file_from_candidates \
        "${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate_ca.cnf" \
        "${INTERMEDIATE_CA_OUTPUT_DIR}/intermediate-ca.cnf" \
        "${SCRIPT_DIR}/../intermediate_ca/intermediate_ca.cnf" \
        "${SCRIPT_DIR}/../intermediate_ca/intermediate-ca.cnf" || true
    )"
    if [[ -n "$resolved_intermediate_config" ]]; then
      export INTERMEDIATE_CA_CONFIG_FILE="$resolved_intermediate_config"
      export LEAF_CONFIG_FILE="${LEAF_CONFIG_FILE:-$resolved_intermediate_config}"
    fi
  elif [[ -z "${LEAF_CONFIG_FILE:-}" ]]; then
    export LEAF_CONFIG_FILE="$INTERMEDIATE_CA_CONFIG_FILE"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: menu.sh must be run as root." >&2
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
    bash "$script_path" "$@"
  else
    "$script_path" "$@"
  fi
}

run_submenu() {
  local script_path="$1"
  shift || true

  local rc=0
  run_script "$script_path" "$@" || rc=$?

  # Submenus use exit code 99 to indicate a full quit request.
  if [[ $rc -eq 99 ]]; then
    exit 0
  fi

  return $rc
}

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") <action> [args ...]

Actions:
  1 | root-ca-actions          Run ${ROOT_MENU_SCRIPT##*/}
  2 | intermediate-ca-actions  Run ${INTERMEDIATE_MENU_SCRIPT##*/}
  3 | leaf-actions             Run ${LEAF_MENU_SCRIPT##*/}
  h | help                     Show this help text
  q | quit                     Exit the menu
EOF
}

interactive_menu() {
  local choice

  while true; do
    cat <<'EOF'
========================================
 PKI Operations Menu
========================================
1) Root CA Actions
2) Intermediate CA Actions
3) Leaf Actions
h) Help
q) Quit
EOF

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        FROM_MAIN_MENU=1 run_submenu "$ROOT_MENU_SCRIPT"
        ;;
      2)
        FROM_MAIN_MENU=1 run_submenu "$INTERMEDIATE_MENU_SCRIPT"
        ;;
      3)
        FROM_MAIN_MENU=1 run_submenu "$LEAF_MENU_SCRIPT"
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
  set_default_output_dirs
  set_default_config_files

  if [[ $# -gt 0 ]]; then
    case "$1" in
      1|root-ca-actions)
        shift
        FROM_MAIN_MENU=1 run_submenu "$ROOT_MENU_SCRIPT" "$@"
        ;;
      2|intermediate-ca-actions)
        shift
        FROM_MAIN_MENU=1 run_submenu "$INTERMEDIATE_MENU_SCRIPT" "$@"
        ;;
      3|leaf-actions)
        shift
        FROM_MAIN_MENU=1 run_submenu "$LEAF_MENU_SCRIPT" "$@"
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
