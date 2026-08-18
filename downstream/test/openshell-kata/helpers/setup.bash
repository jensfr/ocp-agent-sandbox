#!/usr/bin/env bash
# Shared BATS helpers for openshell-kata integration tests.
# Load via: load helpers/setup

# --- Configuration ---
NAMESPACE="${NAMESPACE:-openshell}"
TIMEOUT_CREATE="${TIMEOUT_CREATE:-60}"
TIMEOUT_DELETE="${TIMEOUT_DELETE:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
# OpenShell sandbox names are limited to 19 characters.
SANDBOX_NAME_MAX_LEN=19

# Per-file unique sandbox name: "ci-XXXX" (7 chars, leaves room for suffixes)
_file_hash=$(printf '%04x' $(( $(echo "${BATS_TEST_FILENAME:-unknown}" | cksum | cut -d' ' -f1) % 65536 )))
SANDBOX_NAME="ci-${_file_hash}"

# --- CLI detection ---
if command -v openshell &>/dev/null; then
    USE_OPENSHELL=true
else
    USE_OPENSHELL=false
fi

# Track backgrounded create processes so we can clean them up
OPENSHELL_CREATE_PIDS=()

# --- Sandbox operations ---

create_sandbox() {
    local name="${1:?sandbox name required}"
    shift
    local extra_args=("$@")

    if (( ${#name} > SANDBOX_NAME_MAX_LEN )); then
        echo "Sandbox name '${name}' exceeds ${SANDBOX_NAME_MAX_LEN} char limit" >&2
        return 1
    fi

    # Clean up stale sandbox from a previous run
    delete_sandbox "${name}" 2>/dev/null || true

    if [[ "${USE_OPENSHELL}" == "true" ]]; then
        # Background the create — it blocks until the command exits.
        openshell sandbox create --name "${name}" --no-tty "${extra_args[@]}" -- sleep 3600 &>/dev/null &
        disown $!
        OPENSHELL_CREATE_PIDS+=($!)
        # Poll sandbox list for Ready phase
        local elapsed=0
        while (( elapsed < TIMEOUT_CREATE )); do
            local phase
            # Strip ANSI color codes from output before matching
            phase=$(openshell sandbox list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v name="${name}" '$1 == name {print $NF}' || true)
            if [[ "${phase}" == "Ready" ]]; then
                return 0
            fi
            sleep "${POLL_INTERVAL}"
            (( elapsed += POLL_INTERVAL ))
        done
        echo "Timed out waiting for sandbox ${name} (last phase: ${phase:-unknown})" >&2
        return 1
    else
        _kubectl_create_sandbox "${name}" "${extra_args[@]}"
        _wait_for_sandbox_ready "${name}"
    fi
}

create_sandbox_run() {
    local name="${1:?sandbox name required}"
    shift

    if [[ "${USE_OPENSHELL}" == "true" ]]; then
        openshell sandbox create --name "${name}" --no-keep --no-tty -- "$@"
    else
        _kubectl_create_sandbox "${name}"
        _wait_for_sandbox_ready "${name}"
        kubectl exec -n "${NAMESPACE}" "${name}" -- "$@"
        delete_sandbox "${name}"
    fi
}

exec_in_sandbox() {
    local name="${1:?sandbox name required}"
    shift

    if [[ "${USE_OPENSHELL}" == "true" ]]; then
        openshell sandbox exec --name "${name}" --no-tty -- "$@"
    else
        kubectl exec -n "${NAMESPACE}" "${name}" -- "$@"
    fi
}

delete_sandbox() {
    local name="${1:?sandbox name required}"

    if [[ "${USE_OPENSHELL}" == "true" ]]; then
        openshell sandbox delete "${name}" 2>/dev/null || true
    else
        kubectl delete sandbox -n "${NAMESPACE}" "${name}" --timeout="${TIMEOUT_DELETE}s" 2>/dev/null || true
    fi
}

# --- kubectl fallback helpers ---

_kubectl_create_sandbox() {
    local name="${1:?sandbox name required}"
    shift
    local runtime_class="${RUNTIME_CLASS:-kata}"

    kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: ${name}
spec:
  podTemplate:
    spec:
      runtimeClassName: ${runtime_class}
      containers:
        - name: sandbox
          image: registry.k8s.io/pause:3.10
          command: ["sleep", "3600"]
EOF
}

_wait_for_sandbox_ready() {
    local name="$1"
    local elapsed=0

    while (( elapsed < TIMEOUT_CREATE )); do
        local phase
        phase=$(kubectl get sandbox -n "${NAMESPACE}" "${name}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "${phase}" == "True" ]]; then
            return 0
        fi
        sleep "${POLL_INTERVAL}"
        (( elapsed += POLL_INTERVAL ))
    done
    echo "Timed out waiting for sandbox ${name} to become ready" >&2
    return 1
}

# --- Wait helpers ---

wait_for_pod_gone() {
    local name="$1"
    local namespace="${2:-${NAMESPACE}}"
    local elapsed=0

    while (( elapsed < TIMEOUT_DELETE )); do
        if ! kubectl get pod -n "${namespace}" "${name}" &>/dev/null; then
            return 0
        fi
        sleep "${POLL_INTERVAL}"
        (( elapsed += POLL_INTERVAL ))
    done
    echo "Timed out waiting for pod ${name} to be deleted" >&2
    return 1
}

wait_for_pvc_gone() {
    local name="$1"
    local namespace="${2:-${NAMESPACE}}"
    local elapsed=0

    while (( elapsed < TIMEOUT_DELETE )); do
        if ! kubectl get pvc -n "${namespace}" "${name}" &>/dev/null; then
            return 0
        fi
        sleep "${POLL_INTERVAL}"
        (( elapsed += POLL_INTERVAL ))
    done
    echo "Timed out waiting for PVC ${name} to be deleted" >&2
    return 1
}

# --- Cleanup ---

cleanup_sandbox() {
    local name="${1:-${SANDBOX_NAME}}"
    delete_sandbox "${name}" 2>/dev/null || true
    # Kill any backgrounded create processes
    for pid in "${OPENSHELL_CREATE_PIDS[@]}"; do
        kill "${pid}" 2>/dev/null || true
    done
    OPENSHELL_CREATE_PIDS=()
}
