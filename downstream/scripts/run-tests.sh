#!/usr/bin/env bash
# Runs the BATS test suite and produces JUnit XML output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export_kubeconfig

ARTIFACT_DIR="${ARTIFACTS:-${SCRIPT_DIR}/../bin/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

TEST_DIR="${SCRIPT_DIR}/../test/openshell-kata"

check_binary bats "Install bats-core: https://github.com/bats-core/bats-core#installation"

log_info "Running BATS tests from ${TEST_DIR}..."

bats \
    --formatter junit \
    --output "${ARTIFACT_DIR}" \
    --timing \
    "${TEST_DIR}"/*.bats

EXIT_CODE=$?

if [[ ${EXIT_CODE} -eq 0 ]]; then
    log_info "All tests passed."
else
    log_error "Some tests failed (exit code: ${EXIT_CODE})."
fi

log_info "Test results written to ${ARTIFACT_DIR}"
exit ${EXIT_CODE}
