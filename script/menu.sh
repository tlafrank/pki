#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_root_ca.sh"
INTERMEDIATE_CA_CREATE_SCRIPT="${SCRIPT_DIR}/create_intermediate_ca.sh"
INTERMEDIATE_CA_SIGN_CSR_SCRIPT="${SCRIPT_DIR}/sign_intermediate_csr.sh"
CLIENT_CSR_SIGN_SCRIPT="${SCRIPT_DIR}/sign_client_csr.sh"
CLIENT_CREATE_SIGN_PACKAGE_SCRIPT="${SCRIPT_DIR}/create_sign_package_client.sh"

print_header() {
  cat <<'EOF'
========================================
 PKI Operations Menu
========================================
EOF
}

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0")
  $(basename "$0") <action> [args ...]

Actions:
  1 | create-root-ca               Run ${ROOT_CA_CREATE_SCRIPT##*/}
  2 | create-intermediate-ca       Run ${INTERMEDIATE_CA_CREATE_SCRIPT##*/}
  3 | sign-intermediate-csr        Run ${INTERMEDIATE_CA_SIGN_CSR_SCRIPT##*/}
  4 | sign-client-csr              Run ${CLIENT_CSR_SIGN_SCRIPT##*/}
  5 | create-sign-package-client   Run ${CLIENT_CREATE_SIGN_PACKAGE_SCRIPT##*/}
  h | help                         Show this help text
  q | quit                         Exit the menu

Examples:
  $(basename "$0") create-root-ca
  $(basename "$0") sign-client-csr --help
EOF
}

run_script() {
  local script_path="$1"
  shift || true

  if [[ ! -f "$script_path" ]]; then
    echo "Error: expected script not found: $script_path" >&2
    return 1
  fi

  if [[ ! -x "$script_path" ]]; then
    echo "Note: $script_path is not executable. Running with bash."
    exec bash "$script_path" "$@"
  else
    exec "$script_path" "$@"
  fi
}

dispatch_action() {
  local action="$1"
  shift || true

  case "$action" in
    1|create-root-ca)
      run_script "$ROOT_CA_CREATE_SCRIPT" "$@"
      ;;
    2|create-intermediate-ca)
      run_script "$INTERMEDIATE_CA_CREATE_SCRIPT" "$@"
      ;;
    3|sign-intermediate-csr)
      run_script "$INTERMEDIATE_CA_SIGN_CSR_SCRIPT" "$@"
      ;;
    4|sign-client-csr)
      run_script "$CLIENT_CSR_SIGN_SCRIPT" "$@"
      ;;
    5|create-sign-package-client)
      run_script "$CLIENT_CREATE_SIGN_PACKAGE_SCRIPT" "$@"
      ;;
    h|help|-h|--help)
      print_usage
      ;;
    q|quit|exit)
      exit 0
      ;;
    *)
      echo "Error: unknown action: $action" >&2
      echo >&2
      print_usage >&2
      return 1
      ;;
  esac
}

interactive_menu() {
  local choice

  while true; do
    print_header
    cat <<'EOF'
1) Create root CA keypair and certificate
2) Create intermediate CA keypair and CSR
3) Sign intermediate CA CSR
4) Sign client CSR
5) Create, sign and package client keypair
h) Help
q) Quit
EOF
    echo
    read -r -p "Select an option: " choice
    echo

    case "$choice" in
      1)
        run_script "$ROOT_CA_CREATE_SCRIPT"
        ;;
      2)
        run_script "$INTERMEDIATE_CA_CREATE_SCRIPT"
        ;;
      3)
        run_script "$INTERMEDIATE_CA_SIGN_CSR_SCRIPT"
        ;;
      4)
        run_script "$CLIENT_CSR_SIGN_SCRIPT"
        ;;
      5)
        run_script "$CLIENT_CREATE_SIGN_PACKAGE_SCRIPT"
        ;;
      h|H)
        print_usage
        echo
        read -r -p "Press Enter to continue..." _
        ;;
      q|Q)
        exit 0
        ;;
      *)
        echo "Invalid selection: $choice" >&2
        echo
        read -r -p "Press Enter to continue..." _
        ;;
    esac
  done
}

main() {
  if [[ $# -gt 0 ]]; then
    dispatch_action "$@"
  else
    interactive_menu
  fi
}

main "$@"
