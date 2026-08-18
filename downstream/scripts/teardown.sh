#!/usr/bin/env bash
# Tears down agent-sandbox and OpenShell components.
# Idempotent — safe to call multiple times.
# Does NOT touch OSC operator or KataConfig (those are managed by existing Prow post steps).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export_kubeconfig

log_info "Cleaning up any leftover sandboxes..."
kubectl delete sandboxes --all -A --timeout=30s 2>/dev/null || true

log_info "Tearing down OpenShell gateway..."
helm uninstall openshell-gateway 2>/dev/null || true

log_info "Tearing down agent-sandbox controller..."
helm uninstall agent-sandbox 2>/dev/null || true

log_info "Teardown complete."
