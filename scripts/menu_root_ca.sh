#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Root-CA-focused submenu wrapper for creating root CA and signing intermediate CSRs.
# Interacts with:
# - scripts/create_root_ca.sh
# - scripts/sign_intermediate_csr.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_root_ca.sh"
INTERMEDIATE_CA_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_intermediate_csr.sh"
DEFAULT_PKI_BASE_DIR="${DEFAULT_PKI_BASE_DIR:-/opt/pki}"

set_default_root_ca_env() {
  export ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR}/root-ca}"
  if [[ -z "${ROOT_CA_CONFIG_FILE:-}" ]]; then
    if [[ -f "${ROOT_CA_OUTPUT_DIR}/root_ca.cnf" ]]; then
      export ROOT_CA_CONFIG_FILE="${ROOT_CA_OUTPUT_DIR}/root_ca.cnf"
    elif [[ -f "${ROOT_CA_OUTPUT_DIR}/root-ca.cnf" ]]; then
      export ROOT_CA_CONFIG_FILE="${ROOT_CA_OUTPUT_DIR}/root-ca.cnf"
    elif [[ -f "${SCRIPT_DIR}/../root_ca/root_ca.cnf" ]]; then
      export ROOT_CA_CONFIG_FILE="${SCRIPT_DIR}/../root_ca/root_ca.cnf"
    elif [[ -f "${SCRIPT_DIR}/../root_ca/root-ca.cnf" ]]; then
      export ROOT_CA_CONFIG_FILE="${SCRIPT_DIR}/../root_ca/root-ca.cnf"
    fi
  fi
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

default_intermediate_csr_path() {
  local intermediate_dir="${INTERMEDIATE_CA_OUTPUT_DIR:-${DEFAULT_PKI_BASE_DIR}/intermediate-ca}"
  local intermediate_name="ca-intermediate"
  local name_file="$intermediate_dir/intermediate-ca.name"
  if [[ -f "$name_file" ]]; then
    intermediate_name="$(tr -d '[:space:]' < "$name_file")"
  fi
  printf '%s/csr/%s.csr' "$intermediate_dir" "$intermediate_name"
}

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
  1 | create-root-ca           Run ${ROOT_CA_CREATE_SCRIPT##*/}
  2 | sign-intermediate-csr    Run ${INTERMEDIATE_CA_SIGN_CSR_SCRIPT##*/} <csr-path>
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
 Root CA Actions
========================================
1) Create root CA keypair and certificate
2) Sign intermediate CA CSR
h) Help
q) Quit
EOF
    if [[ "${FROM_MAIN_MENU:-0}" == "1" ]]; then
      echo "b) Back to main menu"
    fi

    read -r -p "Select an option: " choice

    case "$choice" in
      1)
        run_script "$ROOT_CA_CREATE_SCRIPT"
        ;;
      2)
        csr_default="$(default_intermediate_csr_path)"
        csr_path="$(prompt_with_default "Path to intermediate CSR" "$csr_default")"
        run_script "$INTERMEDIATE_CA_SIGN_CSR_SCRIPT" "$csr_path"
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
  set_default_root_ca_env

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
