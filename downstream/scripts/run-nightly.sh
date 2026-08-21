#!/usr/bin/env bash
# Nightly CI runner for agent-sandbox + OpenShell on kata.
# Tests multiple agent-sandbox versions against a stable OpenShell + OSC + kata stack.
#
# Usage: run-nightly.sh [all|ga|downstream|upstream]
#   all        — test all three agent-sandbox variants (default)
#   ga         — GA release only
#   downstream — Konflux-built downstream HEAD only
#   upstream   — upstream release only
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

MODE="${1:-all}"
RESULTS_DIR="/tmp/ci-results/$(date -u '+%Y%m%d-%H%M%S')"
mkdir -p "${RESULTS_DIR}"

# --- Stable stack (pinned, never changes) ---
OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-0.0.105}"
KATA_RPM_VERSION="${KATA_RPM_VERSION:-3.31.0-5}"

# --- Agent Sandbox variants to test ---
declare -A AS_VARIANTS
AS_VARIANTS=(
    [ga]="registry.redhat.io/agent-sandbox/agent-sandbox-rhel9-operator:latest"
    [downstream]="quay.io/redhat-user-workloads/ose-osc-tenant/agent-sandbox-operator:latest"
    [upstream]="registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.5"
)

AS_CONTROLLER_NS="agent-sandbox-system"
AS_CONTROLLER_DEPLOY="agent-sandbox-controller"

START_TIME=$(date +%s)

# --- Cleanup old results ---
find /tmp/ci-results -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

# --- Preflight ---
log_info "=== Nightly CI starting (mode: ${MODE}) ==="
log_info "Stable stack: OpenShell ${OPENSHELL_IMAGE_TAG} | Kata ${KATA_RPM_VERSION}"

if ! kubectl cluster-info &>/dev/null; then
    log_error "Cluster API unreachable"
    notify_failure 0 1 1 "0s" "Cluster unreachable" "Cluster API unreachable" ""
    exit 1
fi

# Verify gateway is running
if ! kubectl get pod -n openshell -l app.kubernetes.io/name=openshell --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
    log_error "OpenShell gateway pod not running"
    notify_failure 0 1 1 "0s" "Gateway down" "OpenShell gateway not running" ""
    exit 1
fi

# Clean stale sandboxes
kubectl delete sandboxes --all -A --timeout=30s 2>/dev/null || true
if command -v openshell &>/dev/null; then
    openshell sandbox delete --all 2>/dev/null || true
fi

# Register gateway
GATEWAY_IP=$(kubectl get svc openshell -n openshell -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -n "${GATEWAY_IP}" ]] && curl -sf -o /dev/null --connect-timeout 2 "http://${GATEWAY_IP}:8080" 2>/dev/null; then
    GATEWAY_ENDPOINT="http://${GATEWAY_IP}:8080"
else
    log_info "Using port-forward for gateway access..."
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

# --- Determine which variants to test ---
VARIANTS_TO_TEST=()
case "${MODE}" in
    all) VARIANTS_TO_TEST=("ga" "downstream" "upstream") ;;
    ga|downstream|upstream) VARIANTS_TO_TEST=("${MODE}") ;;
    *) log_error "Unknown mode: ${MODE}"; exit 1 ;;
esac

# --- Save original controller image for restore ---
ORIGINAL_IMAGE=$(kubectl get deployment "${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

# --- Test each variant ---
ALL_RESULTS=""
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
HAS_FAILURE=0

run_variant() {
    local variant_name="$1"
    local variant_image="$2"
    local variant_dir="${RESULTS_DIR}/${variant_name}"
    mkdir -p "${variant_dir}"

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ">>> Testing: ${variant_name} (${variant_image##*/})"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # --- Swap controller image ---
    log_info "Deploying ${variant_name} controller..."
    kubectl set image "deployment/${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" \
        "${AS_CONTROLLER_DEPLOY}=${variant_image}" 2>&1 || {
        log_error "Failed to set image for ${variant_name}"
        ALL_RESULTS+="SKIP ${variant_name}: failed to deploy ${variant_image}\n"
        return
    }

    # Wait for rollout
    if ! kubectl rollout status "deployment/${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" --timeout=120s 2>&1; then
        log_error "Rollout failed for ${variant_name}"
        ALL_RESULTS+="FAIL ${variant_name}: controller rollout failed\n"
        (( HAS_FAILURE++ )) || true
        # Collect diagnostics
        collect_diagnostics "${variant_dir}/diagnostic-bundle.txt"
        return
    fi

    log_info "Controller running: $(kubectl get deployment "${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"

    # Clean sandboxes between variants
    kubectl delete sandboxes --all -A --timeout=30s 2>/dev/null || true
    if command -v openshell &>/dev/null; then
        openshell sandbox delete --all 2>/dev/null || true
    fi
    sleep 5

    # --- Run BATS tests ---
    local bats_exit=0
    local bats_output="${variant_dir}/bats-output.txt"

    if command -v bats &>/dev/null; then
        bats \
            --report-formatter junit \
            --output "${variant_dir}" \
            --timing \
            "${SCRIPT_DIR}/../test/openshell-kata/"*.bats \
            2>&1 | tee "${bats_output}" || bats_exit=$?
    else
        log_error "bats not found"
        bats_exit=1
        echo "bats not installed" > "${bats_output}"
    fi

    # --- Parse results ---
    local passed=0 failed=0
    if [[ -f "${bats_output}" ]]; then
        passed=$(grep -c '^ok ' "${bats_output}" || true)
        failed=$(grep -c '^not ok ' "${bats_output}" || true)
    fi
    passed=${passed:-0}
    failed=${failed:-0}
    local total=$((passed + failed))

    TOTAL_PASS=$((TOTAL_PASS + passed))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))
    TOTAL_TESTS=$((TOTAL_TESTS + total))

    if (( failed > 0 || bats_exit != 0 )); then
        (( HAS_FAILURE++ )) || true
        local failed_list
        failed_list=$(grep '^not ok ' "${bats_output}" 2>/dev/null | sed 's/^not ok [0-9]* /  - /' || true)
        ALL_RESULTS+="FAIL ${variant_name}: ${passed}/${total} passed\n${failed_list}\n"
        collect_diagnostics "${variant_dir}/diagnostic-bundle.txt"
    else
        ALL_RESULTS+="PASS ${variant_name}: ${passed}/${total} passed\n"
    fi

    log_info ">>> ${variant_name}: ${passed}/${total} passed"
}

for variant in "${VARIANTS_TO_TEST[@]}"; do
    run_variant "${variant}" "${AS_VARIANTS[${variant}]}"
done

# --- Restore original controller ---
if [[ -n "${ORIGINAL_IMAGE}" ]]; then
    log_info "Restoring original controller image..."
    kubectl set image "deployment/${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" \
        "${AS_CONTROLLER_DEPLOY}=${ORIGINAL_IMAGE}" 2>/dev/null || true
fi

# --- Summary ---
END_TIME=$(date +%s)
DURATION="$((END_TIME - START_TIME))s"

STACK_INFO="OpenShell: ${OPENSHELL_IMAGE_TAG} | Kata: ${KATA_RPM_VERSION}"
SUMMARY="Agent Sandbox Nightly CI (${MODE})
Tested ${#VARIANTS_TO_TEST[@]} variant(s) in ${DURATION}
Stack: ${STACK_INFO}

Results:
$(echo -e "${ALL_RESULTS}")
Total: ${TOTAL_PASS}/${TOTAL_TESTS} passed, ${TOTAL_FAIL} failed"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ">>> ${SUMMARY}"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Write to log ---
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $(( HAS_FAILURE > 0 ? 'FAIL' : 'PASS' )) ${SUMMARY}" >> /tmp/ci-results/history.log
echo "${SUMMARY}" > "${RESULTS_DIR}/summary.txt"

# --- Notify ---
if (( HAS_FAILURE > 0 )); then
    # Find first diagnostic bundle
    local_diag=$(find "${RESULTS_DIR}" -name "diagnostic-bundle.txt" -type f | head -1)
    notify_failure "${TOTAL_PASS}" "${TOTAL_FAIL}" "${TOTAL_TESTS}" "${DURATION}" \
        "${STACK_INFO}" "$(echo -e "${ALL_RESULTS}")" "${local_diag:-}"
else
    notify_success "${TOTAL_PASS}/${TOTAL_TESTS} across ${#VARIANTS_TO_TEST[@]} variants" "${DURATION}" "${STACK_INFO}"
fi

log_info "Results saved to ${RESULTS_DIR}"
exit $(( HAS_FAILURE > 0 ? 1 : 0 ))
