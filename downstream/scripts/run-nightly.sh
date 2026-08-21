#!/usr/bin/env bash
# Nightly CI runner for agent-sandbox + OpenShell on kata.
# Designed to run via cron on virtlab725.
#
# Usage: run-nightly.sh [regression|integration]
#   regression  — HEAD against pinned known-good stack (default)
#   integration — HEAD against HEAD (all latest)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/cluster-checks.sh
source "${SCRIPT_DIR}/lib/cluster-checks.sh"
# shellcheck source=lib/slack-notify.sh
source "${SCRIPT_DIR}/lib/slack-notify.sh"
# shellcheck source=lib/collect-diagnostics.sh
source "${SCRIPT_DIR}/lib/collect-diagnostics.sh"

# --- Lockfile: prevent overlapping runs ---
LOCKFILE="/tmp/ci-nightly.lock"
exec 200>"${LOCKFILE}"
if ! flock -n 200; then
    echo "Another nightly CI run is in progress. Exiting."
    exit 0
fi

# --- Global timeout: kill the entire run after 30 minutes ---
TIMEOUT_PID=""
(
    sleep 1800
    log_error "Nightly CI timed out after 30 minutes"
    kill -TERM "$$" 2>/dev/null
) &
TIMEOUT_PID=$!

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    [[ -n "${TIMEOUT_PID}" ]] && kill "${TIMEOUT_PID}" 2>/dev/null || true
    [[ -n "${PF_PID:-}" ]] && kill "${PF_PID}" 2>/dev/null || true
    # Clean up leftover sandboxes
    if command -v openshell &>/dev/null; then
        openshell sandbox delete --all 2>/dev/null || true
    fi
    flock -u 200
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

STRATEGY="${1:-regression}"
RESULTS_DIR="/tmp/ci-results/$(date -u '+%Y%m%d-%H%M%S')"
mkdir -p "${RESULTS_DIR}"

# Load Slack credentials
# shellcheck source=/dev/null
[[ -f /etc/ci/slack-env ]] && source /etc/ci/slack-env

# Version pins per strategy
case "${STRATEGY}" in
    regression)
        export OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-0.0.105}"
        export KATA_RPM_VERSION="${KATA_RPM_VERSION:-3.31.0-5}"
        ;;
    integration)
        export OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-latest}"
        export KATA_RPM_VERSION="${KATA_RPM_VERSION:-latest}"
        ;;
    *)
        log_error "Unknown strategy: ${STRATEGY}. Use 'regression' or 'integration'."
        exit 1
        ;;
esac

STACK_INFO="Strategy: ${STRATEGY} | OpenShell: ${OPENSHELL_IMAGE_TAG} | Kata: ${KATA_RPM_VERSION}"
START_TIME=$(date +%s)

# --- Cleanup old results ---
find /tmp/ci-results -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

# --- Preflight ---
log_info "=== Nightly CI (${STRATEGY}) starting ==="
log_info "${STACK_INFO}"

if ! kubectl cluster-info &>/dev/null; then
    notify_failure 0 1 1 "0s" "${STACK_INFO}" "Cluster API unreachable" ""
    exit 1
fi

# Check and fix common issues
if compgen -G "/etc/kata-containers/config.d/*" &>/dev/null; then
    log_warn "Stale files in kata config.d/ — moving aside"
    for f in /etc/kata-containers/config.d/*; do
        [[ -e "${f}" ]] || continue
        sudo mv "${f}" "/root/$(basename "${f}").moved-by-ci" 2>/dev/null || true
    done
    slack_post "Warning: moved stale kata config drop-ins aside on virtlab725"
fi

# Clean stale sandboxes
if command -v openshell &>/dev/null; then
    openshell sandbox delete --all 2>/dev/null || true
fi
kubectl delete sandboxes --all -A --timeout=30s 2>/dev/null || true

# Verify gateway
if ! kubectl get pod openshell-0 -n openshell &>/dev/null; then
    notify_failure 0 1 1 "0s" "${STACK_INFO}" "OpenShell gateway pod not found" ""
    exit 1
fi

# Register gateway for openshell CLI
if command -v openshell &>/dev/null; then
    openshell gateway remove nightly-ci 2>/dev/null || true
    # Use cluster-internal service URL (running on the node)
    GATEWAY_IP=$(kubectl get svc openshell -n openshell -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [[ -n "${GATEWAY_IP}" ]]; then
        openshell gateway add --name nightly-ci "http://${GATEWAY_IP}:8080" 2>/dev/null || true
    fi
fi

# --- Run BATS tests ---
log_info "=== Running BATS tests ==="
BATS_EXIT=0
BATS_OUTPUT="${RESULTS_DIR}/bats-output.txt"

if command -v bats &>/dev/null; then
    bats \
        --report-formatter junit \
        --output "${RESULTS_DIR}" \
        --timing \
        "${SCRIPT_DIR}/../test/openshell-kata/"*.bats \
        2>&1 | tee "${BATS_OUTPUT}" || BATS_EXIT=$?
else
    log_error "bats not found — skipping BATS tests"
    BATS_EXIT=1
fi

# --- Run upstream Rust e2e tests ---
log_info "=== Running upstream OpenShell Rust e2e tests ==="
E2E_EXIT=0
E2E_OUTPUT="${RESULTS_DIR}/e2e-output.txt"
E2E_BINARY="${E2E_BINARY:-/opt/ci/openshell-e2e}"

if [[ -x "${E2E_BINARY}" ]]; then
    # Start health port-forward
    kubectl -n openshell port-forward pod/openshell-0 8081:health &>/dev/null &
    PF_PID=$!
    sleep 3

    OPENSHELL_BIN="$(command -v openshell || echo /usr/local/bin/openshell)" \
    OPENSHELL_E2E_HEALTH_PORT=8081 \
        "${E2E_BINARY}" --test-threads=1 --nocapture \
        2>&1 | tee "${E2E_OUTPUT}" || E2E_EXIT=$?

    kill "${PF_PID}" 2>/dev/null || true
elif command -v cargo &>/dev/null && [[ -d "${SCRIPT_DIR}/../../OpenShell/e2e/rust" ]]; then
    # Fallback: build and run from source (slow first time)
    "${SCRIPT_DIR}/run-openshell-e2e.sh" 2>&1 | tee "${E2E_OUTPUT}" || E2E_EXIT=$?
else
    log_warn "No Rust e2e binary or cargo — skipping upstream e2e tests"
fi

# --- Parse results ---
END_TIME=$(date +%s)
DURATION="$((END_TIME - START_TIME))s"

BATS_PASSED=0
BATS_FAILED=0
if [[ -f "${BATS_OUTPUT}" ]]; then
    BATS_PASSED=$(grep -c '^ok ' "${BATS_OUTPUT}" 2>/dev/null || echo 0)
    BATS_FAILED=$(grep -c '^not ok ' "${BATS_OUTPUT}" 2>/dev/null || echo 0)
fi

E2E_PASSED=0
E2E_FAILED=0
if [[ -f "${E2E_OUTPUT}" ]]; then
    E2E_PASSED=$(grep 'test result:' "${E2E_OUTPUT}" 2>/dev/null | awk '{sum += $4} END {print sum+0}')
    E2E_FAILED=$(grep 'test result:' "${E2E_OUTPUT}" 2>/dev/null | awk '{sum += $8} END {print sum+0}')
fi

TOTAL_PASSED=$((BATS_PASSED + E2E_PASSED))
TOTAL_FAILED=$((BATS_FAILED + E2E_FAILED))
TOTAL=$((TOTAL_PASSED + TOTAL_FAILED))

# --- Notify ---
if (( TOTAL_FAILED == 0 && BATS_EXIT == 0 && E2E_EXIT == 0 )); then
    log_info "=== All tests passed ==="
    notify_success "${TOTAL_PASSED}/${TOTAL}" "${DURATION}" "${STACK_INFO}"
else
    log_error "=== ${TOTAL_FAILED} test(s) failed ==="

    FAILED_TESTS=""
    if [[ -f "${BATS_OUTPUT}" ]]; then
        FAILED_TESTS+=$(grep '^not ok ' "${BATS_OUTPUT}" 2>/dev/null | sed 's/^not ok [0-9]* /  - /' || true)
    fi
    if [[ -f "${E2E_OUTPUT}" ]]; then
        FAILED_TESTS+=$(grep 'FAILED' "${E2E_OUTPUT}" 2>/dev/null | grep -v 'test result' | sed 's/^/  - /' || true)
    fi

    DIAGNOSTIC_FILE="${RESULTS_DIR}/diagnostic-bundle.txt"
    collect_diagnostics "${DIAGNOSTIC_FILE}"

    # Append test output to diagnostic bundle
    {
        echo ""
        echo "=== BATS Output ==="
        cat "${BATS_OUTPUT}" 2>/dev/null || echo "(no output)"
        echo ""
        echo "=== E2E Output (last 50 lines) ==="
        tail -50 "${E2E_OUTPUT}" 2>/dev/null || echo "(no output)"
    } >> "${DIAGNOSTIC_FILE}"

    notify_failure "${TOTAL_PASSED}" "${TOTAL_FAILED}" "${TOTAL}" "${DURATION}" \
        "${STACK_INFO}" "${FAILED_TESTS}" "${DIAGNOSTIC_FILE}"
fi

log_info "Results saved to ${RESULTS_DIR}"
exit $((BATS_EXIT + E2E_EXIT))
