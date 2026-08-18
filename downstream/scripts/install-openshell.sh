#!/usr/bin/env bash
# Installs the OpenShell gateway via Helm.
# Assumes OSC operator and KataConfig are already deployed (by prior Prow steps).
# Independent of agent-sandbox — can be used with other controllers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/cluster-checks.sh"

export_kubeconfig

# --- Configuration ---
OPENSHELL_CHART="${OPENSHELL_CHART:-${SCRIPT_DIR}/../helm/openshell-gateway}"
OPENSHELL_IMAGE="${OPENSHELL_IMAGE:?OPENSHELL_IMAGE is required}"
OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-latest}"
OPENSHELL_NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
OPENSHELL_LOCAL_STORAGE="${OPENSHELL_LOCAL_STORAGE:-false}"

# --- Pre-flight ---
log_info "Running pre-flight checks..."
run_preflight_checks

# --- Install ---
log_info "Installing OpenShell gateway via Helm..."
log_info "  Chart: ${OPENSHELL_CHART}"
log_info "  Image: ${OPENSHELL_IMAGE}:${OPENSHELL_IMAGE_TAG}"
log_info "  Local storage: ${OPENSHELL_LOCAL_STORAGE}"

helm upgrade --install openshell-gateway "${OPENSHELL_CHART}" \
    --set image.repository="${OPENSHELL_IMAGE}" \
    --set image.tag="${OPENSHELL_IMAGE_TAG}" \
    --set storage.localPath.enabled="${OPENSHELL_LOCAL_STORAGE}" \
    --wait --timeout 120s

# --- Verify ---
wait_for_resource "deployment/openshell-gateway" "${OPENSHELL_NAMESPACE}" "Available" 120

log_info "OpenShell gateway installed successfully."
