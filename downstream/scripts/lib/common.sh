#!/usr/bin/env bash
# Shared shell functions for downstream CI scripts.
# Source this file; do not execute directly.

log_info() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] INFO: $*"
}

log_error() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $*" >&2
}

check_binary() {
    local bin="$1"
    local hint="${2:-}"
    if ! command -v "${bin}" &>/dev/null; then
        log_error "${bin} not found on PATH."
        [[ -n "${hint}" ]] && log_error "  ${hint}"
        return 1
    fi
}

wait_for_resource() {
    local resource="$1"
    local namespace="$2"
    local condition="$3"
    local timeout="${4:-120}"

    log_info "Waiting for ${resource} in ${namespace} (condition=${condition}, timeout=${timeout}s)..."
    kubectl wait "${resource}" \
        --namespace="${namespace}" \
        --for="condition=${condition}" \
        --timeout="${timeout}s"
}

retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1

    while true; do
        if "$@"; then
            return 0
        fi
        if (( attempt >= max_attempts )); then
            log_error "Command failed after ${max_attempts} attempts: $*"
            return 1
        fi
        log_warn "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
        sleep "${delay}"
        (( attempt++ ))
        (( delay = delay < 30 ? delay * 2 : 30 ))
    done
}

export_kubeconfig() {
    if [[ -n "${KUBECONFIG:-}" ]]; then
        return
    fi
    # Prow convention: kubeconfig is written to SHARED_DIR by the cluster provisioning step
    if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
        log_info "Using kubeconfig from SHARED_DIR: ${KUBECONFIG}"
    else
        log_error "KUBECONFIG not set and no kubeconfig found in SHARED_DIR."
        return 1
    fi
}
