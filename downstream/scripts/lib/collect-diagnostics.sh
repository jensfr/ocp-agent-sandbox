#!/usr/bin/env bash
# Collect diagnostic bundle on test failure.
# Source this file after common.sh; do not execute directly.

collect_diagnostics() {
    local output_file="${1:?output file path required}"
    local namespace="${2:-openshell}"

    log_info "Collecting diagnostic bundle..."

    {
        echo "=== Diagnostic Bundle ==="
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Cluster: virtlab725"
        echo ""

        echo "=== Sandbox CRs ==="
        kubectl get sandboxes -A -o yaml 2>&1 || echo "Failed to get sandboxes"
        echo ""

        echo "=== Pods in ${namespace} ==="
        kubectl get pods -n "${namespace}" -o wide 2>&1 || echo "Failed to get pods"
        echo ""

        echo "=== Pod Events ==="
        kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' 2>&1 | tail -30 || echo "Failed to get events"
        echo ""

        echo "=== Agent Sandbox Controller Logs (last 50 lines) ==="
        kubectl logs deployment/agent-sandbox-controller -n agent-sandbox-system --tail=50 2>&1 || echo "Failed to get controller logs"
        echo ""

        echo "=== OpenShell Gateway Logs (last 50 lines) ==="
        kubectl logs pod/openshell-0 -n "${namespace}" --tail=50 2>&1 || echo "Failed to get gateway logs"
        echo ""

        echo "=== Kata Config Drop-ins ==="
        ls -la /etc/kata-containers/config.d/ 2>&1 || echo "Cannot read config.d (not on node?)"
        echo ""

        echo "=== Node Resources ==="
        kubectl top nodes 2>&1 || echo "Metrics not available"
        echo ""

        echo "=== Sandbox CR Conditions (summary) ==="
        kubectl get sandboxes -A -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}' 2>&1 || true
        echo ""

    } > "${output_file}" 2>&1

    log_info "Diagnostic bundle saved to ${output_file}"
}
