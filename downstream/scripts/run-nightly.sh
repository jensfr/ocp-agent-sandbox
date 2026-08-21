#!/usr/bin/env bash
# Nightly CI runner for agent-sandbox + OpenShell on kata.
# Runs as an OpenShift CronJob pod or manually from any host with kubectl access.
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

# --- Cleanup trap ---
PF_PID=""
cleanup() {
    local exit_code=$?
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    if command -v openshell &>/dev/null; then
        openshell sandbox delete --all 2>/dev/null || true
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

STRATEGY="${1:-regression}"
RESULTS_DIR="/tmp/ci-results/$(date -u '+%Y%m%d-%H%M%S')"
mkdir -p "${RESULTS_DIR}"

# Version pins per strategy (overridable via env vars from CronJob)
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
    log_error "Cluster API unreachable"
    notify_failure 0 1 1 "0s" "${STACK_INFO}" "Cluster API unreachable" ""
    exit 1
fi

# Verify gateway pod is running
if ! kubectl get pod -n openshell -l app.kubernetes.io/name=openshell --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
    log_error "OpenShell gateway pod not running"
    notify_failure 0 1 1 "0s" "${STACK_INFO}" "OpenShell gateway pod not running" ""
    exit 1
fi

# Clean stale sandboxes
kubectl delete sandboxes --all -A --timeout=30s 2>/dev/null || true
if command -v openshell &>/dev/null; then
    openshell sandbox delete --all 2>/dev/null || true
fi

# Register gateway — use ClusterIP if in-cluster, port-forward if external
GATEWAY_IP=$(kubectl get svc openshell -n openshell -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -n "${GATEWAY_IP}" ]] && curl -sf -o /dev/null --connect-timeout 2 "http://${GATEWAY_IP}:8080" 2>/dev/null; then
    GATEWAY_ENDPOINT="http://${GATEWAY_IP}:8080"
else
    log_info "ClusterIP not reachable (running outside cluster?), using port-forward..."
    LOCAL_PORT=18080
    kubectl -n openshell port-forward svc/openshell "${LOCAL_PORT}:8080" &>/dev/null &
    PF_PID=$!
    sleep 3
    GATEWAY_ENDPOINT="http://127.0.0.1:${LOCAL_PORT}"
fi

if command -v openshell &>/dev/null; then
    openshell gateway remove nightly-ci 2>/dev/null || true
    openshell gateway add --name nightly-ci "${GATEWAY_ENDPOINT}" 2>/dev/null || true
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
    echo "bats not installed" > "${BATS_OUTPUT}"
fi

# --- Run upstream Rust e2e tests ---
log_info "=== Running upstream OpenShell Rust e2e tests ==="
E2E_EXIT=0
E2E_OUTPUT="${RESULTS_DIR}/e2e-output.txt"
E2E_BINARY="${E2E_BINARY:-/usr/local/bin/openshell-e2e}"

if [[ -x "${E2E_BINARY}" ]]; then
    # Health port-forward for readyz test
    HEALTH_PORT=8081
    GATEWAY_POD=$(kubectl get pods -n openshell -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "openshell-0")
    kubectl -n openshell port-forward "pod/${GATEWAY_POD}" "${HEALTH_PORT}:health" &>/dev/null &
    local_pf_pid=$!
    sleep 3

    OPENSHELL_BIN="$(command -v openshell || echo /usr/local/bin/openshell)" \
    OPENSHELL_E2E_HEALTH_PORT="${HEALTH_PORT}" \
        "${E2E_BINARY}" --test-threads=1 --nocapture \
        2>&1 | tee "${E2E_OUTPUT}" || E2E_EXIT=$?

    kill "${local_pf_pid}" 2>/dev/null || true
else
    log_warn "Rust e2e binary not found at ${E2E_BINARY} — skipping"
    echo "e2e binary not found" > "${E2E_OUTPUT}"
fi

# --- Parse results ---
END_TIME=$(date +%s)
DURATION="$(( END_TIME - START_TIME ))s"

BATS_PASSED=$(grep -c '^ok ' "${BATS_OUTPUT}" 2>/dev/null || echo 0)
BATS_FAILED=$(grep -c '^not ok ' "${BATS_OUTPUT}" 2>/dev/null || echo 0)

E2E_PASSED=0
E2E_FAILED=0
if [[ -f "${E2E_OUTPUT}" ]] && grep -q 'test result:' "${E2E_OUTPUT}"; then
    E2E_PASSED=$(awk '/test result:/{sum += $4} END {print sum+0}' "${E2E_OUTPUT}" || echo 0)
    E2E_FAILED=$(awk '/test result:/{sum += $8} END {print sum+0}' "${E2E_OUTPUT}" || echo 0)
fi

TOTAL_PASSED=$(( ${BATS_PASSED:-0} + ${E2E_PASSED:-0} ))
TOTAL_FAILED=$(( ${BATS_FAILED:-0} + ${E2E_FAILED:-0} ))
TOTAL=$(( TOTAL_PASSED + TOTAL_FAILED ))

log_info "Results: ${TOTAL_PASSED}/${TOTAL} passed (${BATS_PASSED} BATS + ${E2E_PASSED} e2e), ${TOTAL_FAILED} failed, ${DURATION}"

# --- Notify ---
if (( TOTAL_FAILED == 0 && BATS_EXIT == 0 && E2E_EXIT == 0 )); then
    log_info "=== All tests passed ==="
    notify_success "${TOTAL_PASSED}/${TOTAL} (${BATS_PASSED} BATS + ${E2E_PASSED} e2e)" "${DURATION}" "${STACK_INFO}"
else
    log_error "=== ${TOTAL_FAILED} test(s) failed ==="

    FAILED_TESTS=""
    [[ -f "${BATS_OUTPUT}" ]] && FAILED_TESTS+=$(grep '^not ok ' "${BATS_OUTPUT}" 2>/dev/null | sed 's/^not ok [0-9]* /  - /' || true)
    [[ -f "${E2E_OUTPUT}" ]] && FAILED_TESTS+=$(grep 'FAILED' "${E2E_OUTPUT}" 2>/dev/null | grep -v 'test result' | sed 's/^/  - /' || true)

    DIAGNOSTIC_FILE="${RESULTS_DIR}/diagnostic-bundle.txt"
    collect_diagnostics "${DIAGNOSTIC_FILE}"

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
exit $(( BATS_EXIT > 0 || E2E_EXIT > 0 ? 1 : 0 ))
