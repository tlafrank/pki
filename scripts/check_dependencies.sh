#!/usr/bin/env bash
set -euo pipefail

# Script purpose:
# - Verifies required CLI tools and Python packages used by this repository.
# Interacts with:
# - api/requirements-dev.txt (and nested -r includes) for package checks.
# - scripts and API runtime prerequisites (openssl, keytool, python3).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

missing=0

check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "[OK] command found: $command_name"
  else
    echo "[MISSING] command not found: $command_name"
    missing=1
  fi
}

parse_requirements() {
  local requirements_file="$1"
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[$'\t\r\n ']/}"
    [ -z "$line" ] && continue

    if [[ "$line" == -r* ]]; then
      local nested_file="${line#-r}"
      parse_requirements "$(dirname "$requirements_file")/$nested_file"
      continue
    fi

    line="${line%%[*}"
    line="${line%%=*}"
    line="${line%%<*}"
    line="${line%%>*}"
    line="${line%%!*}"

    [ -z "$line" ] && continue
    echo "$line"
  done < "$requirements_file"
}

check_python_package() {
  local package_name="$1"
  if python3 -m pip show "$package_name" >/dev/null 2>&1; then
    echo "[OK] python package installed: $package_name"
  else
    echo "[MISSING] python package not installed: $package_name"
    missing=1
  fi
}

echo "Checking required CLI dependencies..."
check_command openssl
check_command keytool
check_command python3

echo
echo "Checking API Python package dependencies..."
requirements_file="$REPO_ROOT/api/requirements-dev.txt"
if [ ! -f "$requirements_file" ]; then
  echo "[MISSING] requirements file not found: $requirements_file"
  missing=1
else
  mapfile -t packages < <(parse_requirements "$requirements_file" | sort -u)
  if [ "${#packages[@]}" -eq 0 ]; then
    echo "[WARN] no package entries found in $requirements_file"
  else
    for package in "${packages[@]}"; do
      check_python_package "$package"
    done
  fi
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "All dependencies are installed."
else
  echo "One or more dependencies are missing."
  exit 1
fi
