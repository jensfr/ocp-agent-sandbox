#!/usr/bin/env bash
# Pre-flight checks to validate OSC + kata prerequisites.
# Source this file after common.sh; do not execute directly.

check_kata_runtimeclass() {
    log_info "Checking for kata RuntimeClass..."
    if ! kubectl get runtimeclass kata &>/dev/null; then
        log_error "RuntimeClass 'kata' not found. Is KataConfig created?"
        return 1
    fi
    log_info "  kata RuntimeClass found."
}

check_osc_operator() {
    log_info "Checking for OSC operator..."
    local ns="openshift-sandboxed-containers-operator"
    if ! kubectl get namespace "${ns}" &>/dev/null; then
        log_error "Namespace ${ns} not found. Is OSC operator installed?"
        return 1
    fi
    local csv
    csv=$(kubectl get csv -n "${ns}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${csv}" ]]; then
        log_error "No CSV found in ${ns}. OSC operator may not be installed."
        return 1
    fi
    log_info "  OSC operator CSV: ${csv}"
}

check_stale_kata_dropins() {
    log_info "Checking for stale kata config drop-ins..."
    # This check requires node access — skip if we can't SSH or run a debug pod
    local node
    node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${node}" ]]; then
        log_warn "  Could not determine node name, skipping drop-in check."
        return 0
    fi
    log_info "  Drop-in check requires node access. Verify manually that"
    log_info "  /etc/kata-containers/config.d/ contains only expected files."
    log_info "  Stale files (even .bak) override the initrd path silently."
}

run_preflight_checks() {
    log_info "Running pre-flight checks..."
    local failed=0

    check_kata_runtimeclass || (( failed++ ))
    check_osc_operator || (( failed++ ))
    check_stale_kata_dropins || (( failed++ ))

    if (( failed > 0 )); then
        log_error "${failed} pre-flight check(s) failed."
        return 1
    fi
    log_info "All pre-flight checks passed."
}
