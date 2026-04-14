#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

ROOT_CA_SCRIPT="${SCRIPTS_DIR}/create_root_ca.sh"
CREATE_INTERMEDIATE_SCRIPT="${SCRIPTS_DIR}/create_intermediate_ca.sh"
SIGN_INTERMEDIATE_SCRIPT="${SCRIPTS_DIR}/sign_intermediate_csr.sh"
CREATE_SIGN_PACKAGE_LEAF_SCRIPT="${SCRIPTS_DIR}/create_sign_package_leaf.sh"

# Explicit, fixed settings for a deterministic full test run.
ALLOW_NON_ROOT="1"
#WORK_DIR="${SCRIPT_DIR}/output/fulltest"
WORK_DIR="/opt/pki"
ROOT_CA_OUTPUT_DIR="${WORK_DIR}/root_ca"
INTERMEDIATE_CA_OUTPUT_DIR="${WORK_DIR}/intermediate_ca"
LEAF_OUTPUT_DIR="${WORK_DIR}/leaf"

ROOT_CA_CONFIG_FILE="${REPO_ROOT}/root_ca/root_ca.cnf"
INTERMEDIATE_CA_CONFIG_FILE="${REPO_ROOT}/intermediate_ca/intermediate_ca.cnf"
P12_PASSWORD="changeit"

ROOT_DAYS="7300"
ROOT_ORG="Example Org PKI"
ROOT_OU="Root CA"
ROOT_CN="Example Root CA"

INTERMEDIATE_DAYS="3650"
INTERMEDIATE_ORG="Example Org PKI"
INTERMEDIATE_OU="Intermediate CA"
INTERMEDIATE_CN="Example Intermediate CA"

LEAF_DAYS="825"
LEAF_ORG="Example Org PKI"
LEAF_OU="Intermediate CA"
LEAF_CN="Example Intermediate CA"

SERVER_CN="server.fulltest.local"
ADMIN_CN="admin.fulltest.local"
CLIENT_CN="client.fulltest.local"
SERVER_SAN_IP="192.168.56.102"

COLOR_HIGHLIGHT='\033[1;36m'
COLOR_RESET='\033[0m'


rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

echo "Running with explicit settings:"
echo "  ALLOW_NON_ROOT=${ALLOW_NON_ROOT}"
echo "  WORK_DIR=${WORK_DIR}"
echo "  ROOT_CA_OUTPUT_DIR=${ROOT_CA_OUTPUT_DIR}"
echo "  INTERMEDIATE_CA_OUTPUT_DIR=${INTERMEDIATE_CA_OUTPUT_DIR}"
echo "  LEAF_OUTPUT_DIR=${LEAF_OUTPUT_DIR}"
echo "  ROOT_CA_CONFIG_FILE=${ROOT_CA_CONFIG_FILE}"
echo "  INTERMEDIATE_CA_CONFIG_FILE=${INTERMEDIATE_CA_CONFIG_FILE}"
echo "  ROOT_DAYS=${ROOT_DAYS}, ROOT_ORG=${ROOT_ORG}, ROOT_OU=${ROOT_OU}, ROOT_CN=${ROOT_CN}"
echo "  INTERMEDIATE_DAYS=${INTERMEDIATE_DAYS}, INTERMEDIATE_ORG=${INTERMEDIATE_ORG}, INTERMEDIATE_OU=${INTERMEDIATE_OU}, INTERMEDIATE_CN=${INTERMEDIATE_CN}"
echo "  LEAF_DAYS=${LEAF_DAYS}, LEAF_ORG=${LEAF_ORG}, LEAF_OU=${LEAF_OU}, LEAF_CN=${LEAF_CN}"
echo "  SERVER_CN=${SERVER_CN}, ADMIN_CN=${ADMIN_CN}, CLIENT_CN=${CLIENT_CN}, SERVER_SAN_IP=${SERVER_SAN_IP}"

echo -e "${COLOR_HIGHLIGHT}[1/6] Creating self-signed root CA${COLOR_RESET}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR}" \
ROOT_CA_CONFIG_FILE="${ROOT_CA_CONFIG_FILE}" \
DAYS="${ROOT_DAYS}" ORG="${ROOT_ORG}" OU="${ROOT_OU}" CN="${ROOT_CN}" \
"${ROOT_CA_SCRIPT}"

echo -e "${COLOR_HIGHLIGHT}[2/6]" "Creating intermediate CA key + CSR${COLOR_RESET}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR}" \
INTERMEDIATE_CA_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE}" \
DAYS="${INTERMEDIATE_DAYS}" ORG="${INTERMEDIATE_ORG}" OU="${INTERMEDIATE_OU}" CN="${INTERMEDIATE_CN}" \
"${CREATE_INTERMEDIATE_SCRIPT}"

echo -e "${COLOR_HIGHLIGHT}[3/6]" "Signing intermediate CA CSR with root CA${COLOR_RESET}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
ROOT_CA_OUTPUT_DIR="${ROOT_CA_OUTPUT_DIR}" \
ROOT_CA_CONFIG_FILE="${ROOT_CA_CONFIG_FILE}" \
DAYS="${INTERMEDIATE_DAYS}" ORG="${ROOT_ORG}" OU="${ROOT_OU}" CN="${ROOT_CN}" \
"${SIGN_INTERMEDIATE_SCRIPT}" "${INTERMEDIATE_CA_OUTPUT_DIR}/csr/intermediate-ca.csr.pem"

echo -e "${COLOR_HIGHLIGHT}[4/6]" "Copying root exports into intermediate CA folders${COLOR_RESET}"
mkdir -p "${INTERMEDIATE_CA_OUTPUT_DIR}/certs" "${INTERMEDIATE_CA_OUTPUT_DIR}/exports"
cp "${ROOT_CA_OUTPUT_DIR}/exports/intermediate-ca.cert.pem" "${INTERMEDIATE_CA_OUTPUT_DIR}/certs/intermediate-ca.cert.pem"
cp "${ROOT_CA_OUTPUT_DIR}/exports/ca-chain-cert.pem" "${INTERMEDIATE_CA_OUTPUT_DIR}/certs/ca-chain-cert.pem"
cp "${ROOT_CA_OUTPUT_DIR}/exports/ca-chain-cert.pem" "${INTERMEDIATE_CA_OUTPUT_DIR}/exports/ca-chain-cert.pem"
cp "${ROOT_CA_OUTPUT_DIR}/exports/root-ca.cert.pem" "${INTERMEDIATE_CA_OUTPUT_DIR}/certs/root-ca.cert.pem"

echo -e "${COLOR_HIGHLIGHT}[5/6]" "Creating client and admin key/cert + p12 bundles${COLOR_RESET}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR}" \
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR}" \
LEAF_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE}" \
DAYS="${LEAF_DAYS}" ORG="${LEAF_ORG}" OU="${LEAF_OU}" CN="${LEAF_CN}" \
"${CREATE_SIGN_PACKAGE_LEAF_SCRIPT}" client "${CLIENT_CN}" "${P12_PASSWORD}"

ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR}" \
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR}" \
LEAF_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE}" \
DAYS="${LEAF_DAYS}" ORG="${LEAF_ORG}" OU="${LEAF_OU}" CN="${LEAF_CN}" \
"${CREATE_SIGN_PACKAGE_LEAF_SCRIPT}" admin "${ADMIN_CN}" "${P12_PASSWORD}"

echo -e "${COLOR_HIGHLIGHT}[6/6]" "Creating server key/cert + p12 bundle with SAN IP ${SERVER_SAN_IP}${COLOR_RESET}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT}" \
INTERMEDIATE_CA_OUTPUT_DIR="${INTERMEDIATE_CA_OUTPUT_DIR}" \
LEAF_OUTPUT_DIR="${LEAF_OUTPUT_DIR}" \
LEAF_CONFIG_FILE="${INTERMEDIATE_CA_CONFIG_FILE}" \
DAYS="${LEAF_DAYS}" ORG="${LEAF_ORG}" OU="${LEAF_OU}" CN="${LEAF_CN}" \
"${CREATE_SIGN_PACKAGE_LEAF_SCRIPT}" server "${SERVER_CN}" "${P12_PASSWORD}" --san-ip "${SERVER_SAN_IP}"

echo -e "Copying p12 bundles from intermediate exports into leaf profile certs folders"
mkdir -p "${LEAF_OUTPUT_DIR}/server/certs" "${LEAF_OUTPUT_DIR}/admin/certs" "${LEAF_OUTPUT_DIR}/client/certs"
cp "${INTERMEDIATE_CA_OUTPUT_DIR}/exports/server-${SERVER_CN}.p12" "${LEAF_OUTPUT_DIR}/server/certs/server-${SERVER_CN}.p12"
cp "${INTERMEDIATE_CA_OUTPUT_DIR}/exports/admin-${ADMIN_CN}.p12" "${LEAF_OUTPUT_DIR}/admin/certs/admin-${ADMIN_CN}.p12"
cp "${INTERMEDIATE_CA_OUTPUT_DIR}/exports/client-${CLIENT_CN}.p12" "${LEAF_OUTPUT_DIR}/client/certs/client-${CLIENT_CN}.p12"

echo
echo "Full PKI workflow completed successfully."
echo "Artifacts: ${WORK_DIR}"
