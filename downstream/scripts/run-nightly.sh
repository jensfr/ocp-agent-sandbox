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
# shellcheck source=lib/run-history.sh
source "${SCRIPT_DIR}/lib/run-history.sh"

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
# GA uses the digest from the original OLM install (no :latest on registry.redhat.io)
# Downstream resolves the latest Konflux-built commit tag at runtime
# Upstream uses the published release image

# Resolve latest downstream Konflux tag (latest main commit SHA)
DOWNSTREAM_REPO="quay.io/redhat-user-workloads/ose-osc-tenant/agent-sandbox-operator"
if [[ -z "${AS_DOWNSTREAM_IMAGE:-}" ]]; then
    LATEST_DOWNSTREAM_TAG=$(curl -sf "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/agent-sandbox-operator/tag/?limit=20&onlyActiveTags=true" 2>/dev/null | \
        python3 -c "import json,sys; tags=[t['name'] for t in json.load(sys.stdin).get('tags',[]) if len(t['name'])==40 and not t['name'].startswith('on-pr') and not t['name'].startswith('sha256')]; print(tags[0] if tags else '')" 2>/dev/null || true)
    if [[ -n "${LATEST_DOWNSTREAM_TAG}" ]]; then
        log_info "Resolved latest downstream tag: ${LATEST_DOWNSTREAM_TAG}"
        AS_DOWNSTREAM_IMAGE="${DOWNSTREAM_REPO}:${LATEST_DOWNSTREAM_TAG}"
    else
        log_warn "Could not resolve latest downstream tag, using hardcoded"
        AS_DOWNSTREAM_IMAGE="${DOWNSTREAM_REPO}:0c3addf0173ad8ee68eb0fb124a6affa5f9aacab"
    fi
fi

declare -A AS_VARIANTS
AS_VARIANTS=(
    [ga]="${AS_GA_IMAGE:-registry.redhat.io/agent-sandbox/agent-sandbox-rhel9-operator@sha256:554102df4c721bd27be7129c910c206ed1329be14df68906a588959b0e7d9309}"
    [downstream]="${AS_DOWNSTREAM_IMAGE}"
    [upstream-release]="${AS_UPSTREAM_RELEASE_IMAGE:-registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.6}"
    [upstream-head]="${AS_UPSTREAM_HEAD_IMAGE:-quay.io/jensfr/agent-sandbox-controller:upstream-head}"
)

AS_CONTROLLER_NS="agent-sandbox-system"
AS_CONTROLLER_DEPLOY="agent-sandbox-controller"
AS_CSV_NAME="agent-sandbox-operator.v0.9.0"

swap_controller_image() {
    local image="$1"
    # Patch the CSV — OLM reconciles the Deployment from the CSV, so patching
    # the Deployment directly gets reverted. Patching the CSV is the stable way.
    kubectl -n "${AS_CONTROLLER_NS}" patch csv "${AS_CSV_NAME}" --type='json' \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\",\"value\":\"${image}\"}]" 2>&1

    # Also set imagePullPolicy to allow localhost images
    local pull_policy="IfNotPresent"
    if [[ "${image}" == localhost/* ]]; then
        pull_policy="Never"
    fi
    kubectl -n "${AS_CONTROLLER_NS}" patch csv "${AS_CSV_NAME}" --type='json' \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"${pull_policy}\"}]" 2>/dev/null || true

    # Wait for OLM to reconcile the Deployment
    sleep 10
}

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
    all)
        VARIANTS_TO_TEST=("ga" "downstream" "upstream-release" "upstream-head")
        ;;
    ga|downstream|upstream-release|upstream-head)
        VARIANTS_TO_TEST=("${MODE}")
        ;;
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
declare -A VARIANT_RESULTS_JSON

# Load previous run state for comparison
load_previous_state

run_variant() {
    local variant_name="$1"
    local variant_image="$2"
    local variant_dir="${RESULTS_DIR}/${variant_name}"
    mkdir -p "${variant_dir}"

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ">>> Testing: ${variant_name} (${variant_image##*/})"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # --- Swap controller image via CSV (OLM-managed) ---
    log_info "Deploying ${variant_name} controller..."
    swap_controller_image "${variant_image}" || {
        log_error "Failed to set image for ${variant_name}"
        ALL_RESULTS+="SKIP ${variant_name}: failed to deploy ${variant_image}\n"
        return
    }

    # Wait for rollout with new image
    if ! kubectl rollout status "deployment/${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" --timeout=120s 2>&1; then
        log_error "Rollout failed for ${variant_name}"
        ALL_RESULTS+="FAIL ${variant_name}: controller rollout failed\n"
        (( HAS_FAILURE++ )) || true
        collect_diagnostics "${variant_dir}/diagnostic-bundle.txt"
        return
    fi

    # Verify the image actually changed
    local actual_image
    actual_image=$(kubectl get deployment "${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    log_info "Controller running: ${actual_image}"
    if [[ "${actual_image}" != "${variant_image}" ]]; then
        log_warn "Image mismatch: expected ${variant_image##*/}, got ${actual_image##*/}"
    fi

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

    # Collect per-test results as JSON for history comparison
    local variant_json
    variant_json=$(python3 -c "
import json, sys
failed = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if line.startswith('not ok '):
                # Strip 'not ok N ' prefix and ' # in Nms' suffix
                name = line.strip().split(' ', 3)[-1].split(' #')[0] if len(line.strip().split(' ', 3)) > 3 else line.strip()
                failed.append(name)
except: pass
print(json.dumps({'passed': int(sys.argv[2]), 'failed': int(sys.argv[3]), 'total': int(sys.argv[4]), 'failed_tests': failed}))
" "${bats_output}" "${passed}" "${failed}" "${total}" 2>/dev/null || echo '{"passed":0,"failed":0,"total":0,"failed_tests":[]}')
    VARIANT_RESULTS_JSON[${variant_name}]="${variant_json}"

    log_info ">>> ${variant_name}: ${passed}/${total} passed"
}

for variant in "${VARIANTS_TO_TEST[@]}"; do
    run_variant "${variant}" "${AS_VARIANTS[${variant}]}"
done

# --- Restore original controller ---
if [[ -n "${ORIGINAL_IMAGE}" ]]; then
    log_info "Restoring original controller image..."
    swap_controller_image "${ORIGINAL_IMAGE}" 2>/dev/null || true
fi

# --- Summary ---
END_TIME=$(date +%s)
DURATION="$((END_TIME - START_TIME))s"

# --- Build JSON for all variants ---
# Write each variant's JSON to a temp file, then merge with Python
RESULTS_TMPFILE=$(mktemp)
for v in "${VARIANTS_TO_TEST[@]}"; do
    echo "${v}=${VARIANT_RESULTS_JSON[${v}]:-"{}"}" >> "${RESULTS_TMPFILE}"
done
RESULTS_JSON=$(python3 -c "
import json, sys
result = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    key, val = line.split('=', 1)
    result[key] = json.loads(val)
print(json.dumps(result))
" "${RESULTS_TMPFILE}" 2>&1) || RESULTS_JSON="{}"
rm -f "${RESULTS_TMPFILE}"

# --- Get upstream changelog ---
CURRENT_UPSTREAM_SHA=""
if [[ -n "${AS_VARIANTS[upstream-head]:-}" ]]; then
    CURRENT_UPSTREAM_SHA=$(skopeo inspect "docker://${AS_VARIANTS[upstream-head]}" 2>/dev/null | \
        python3 -c "import json,sys; labels=json.load(sys.stdin).get('Labels',{}); print(labels.get('org.opencontainers.image.revision',''))" 2>/dev/null || true)
    if [[ -z "${CURRENT_UPSTREAM_SHA}" ]]; then
        # Fallback: extract from image tag
        CURRENT_UPSTREAM_SHA=$(kubectl get deployment "${AS_CONTROLLER_DEPLOY}" -n "${AS_CONTROLLER_NS}" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oE '[a-f0-9]{7,40}' | tail -1 || true)
    fi
fi

UPSTREAM_CHANGELOG=""
if [[ -n "${CURRENT_UPSTREAM_SHA}" ]]; then
    UPSTREAM_CHANGELOG=$(get_upstream_changelog "${CURRENT_UPSTREAM_SHA}")
fi

# --- Compare with previous run ---
RESULT_COMPARISON=$(compare_results "${RESULTS_JSON}")

# --- Save state for next run ---
save_run_state "${RESULTS_JSON}"

STACK_INFO="OpenShell: ${OPENSHELL_IMAGE_TAG} | Kata: ${KATA_RPM_VERSION}"
SUMMARY="Agent Sandbox Nightly CI (${MODE})
Tested ${#VARIANTS_TO_TEST[@]} variant(s) in ${DURATION}
Stack: ${STACK_INFO}

Results:
$(echo -e "${ALL_RESULTS}")
Total: ${TOTAL_PASS}/${TOTAL_TESTS} passed, ${TOTAL_FAIL} failed

${RESULT_COMPARISON}
${UPSTREAM_CHANGELOG:+
Upstream commits:
${UPSTREAM_CHANGELOG}}"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ">>> ${SUMMARY}"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Write to log ---
local_status="PASS"
(( HAS_FAILURE > 0 )) && local_status="FAIL"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${local_status} ${SUMMARY}" >> /tmp/ci-results/history.log
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
