#!/usr/bin/env bash
# Runs upstream OpenShell Rust e2e tests against an already-deployed gateway.
# Assumes agent-sandbox + OpenShell gateway are installed by prior Prow steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export_kubeconfig

# --- Configuration ---
OPENSHELL_REPO="${OPENSHELL_REPO:-/Users/jfreiman/code/OpenShell}"
OPENSHELL_BIN="${OPENSHELL_BIN:-$(command -v openshell || echo /opt/homebrew/bin/openshell)}"
OPENSHELL_NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
OPENSHELL_GATEWAY_POD="${OPENSHELL_GATEWAY_POD:-openshell-0}"
OPENSHELL_E2E_FEATURES="${OPENSHELL_E2E_FEATURES:-e2e-kubernetes}"
OPENSHELL_E2E_TEST="${OPENSHELL_E2E_TEST:-}"
HEALTH_PORT="${OPENSHELL_E2E_HEALTH_PORT:-8081}"

# --- Validate prerequisites ---
check_binary cargo "Install Rust toolchain: https://rustup.rs"
if [[ ! -x "${OPENSHELL_BIN}" ]]; then
    log_error "openshell CLI not found at ${OPENSHELL_BIN}"
    log_error "Set OPENSHELL_BIN or install openshell."
    exit 1
fi
if [[ ! -d "${OPENSHELL_REPO}/e2e/rust" ]]; then
    log_error "OpenShell repo not found at ${OPENSHELL_REPO}/e2e/rust"
    log_error "Set OPENSHELL_REPO to the OpenShell checkout path."
    exit 1
fi

# --- Start health port-forward ---
log_info "Starting health port-forward (${OPENSHELL_GATEWAY_POD}:${HEALTH_PORT})..."
kubectl -n "${OPENSHELL_NAMESPACE}" port-forward "pod/${OPENSHELL_GATEWAY_POD}" "${HEALTH_PORT}:health" &>/tmp/pf-health-e2e.log &
PF_PID=$!

cleanup() {
    kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for port-forward to be ready
local_elapsed=0
while (( local_elapsed < 15 )); do
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${HEALTH_PORT}/healthz" 2>/dev/null; then
        break
    fi
    sleep 1
    (( local_elapsed++ ))
done
if (( local_elapsed >= 15 )); then
    log_error "Health port-forward did not become reachable within 15s."
    cat /tmp/pf-health-e2e.log >&2 || true
    exit 1
fi

# --- Build test filter ---
test_args=()
if [[ -n "${OPENSHELL_E2E_TEST}" ]]; then
    test_args+=(--test "${OPENSHELL_E2E_TEST}")
fi

# --- Run tests ---
log_info "Running OpenShell upstream e2e tests..."
log_info "  Repo: ${OPENSHELL_REPO}"
log_info "  CLI: ${OPENSHELL_BIN}"
log_info "  Features: ${OPENSHELL_E2E_FEATURES}"
log_info "  Test filter: ${OPENSHELL_E2E_TEST:-all}"

cd "${OPENSHELL_REPO}/e2e/rust"

OPENSHELL_BIN="${OPENSHELL_BIN}" \
OPENSHELL_E2E_HEALTH_PORT="${HEALTH_PORT}" \
    cargo test \
        --features "${OPENSHELL_E2E_FEATURES}" \
        ${test_args[@]+"${test_args[@]}"} \
        -- --nocapture

EXIT_CODE=$?

if [[ ${EXIT_CODE} -eq 0 ]]; then
    log_info "All upstream e2e tests passed."
else
    log_error "Upstream e2e tests failed (exit code: ${EXIT_CODE})."
fi

exit ${EXIT_CODE}
