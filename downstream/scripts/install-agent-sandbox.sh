#!/usr/bin/env bash
# Installs the agent-sandbox controller via Helm.
# Assumes OSC operator and KataConfig are already deployed (by prior Prow steps).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export_kubeconfig

# --- Configuration ---
AGENT_SANDBOX_CHART="${AGENT_SANDBOX_CHART:-$(cd "${SCRIPT_DIR}/../../helm" && pwd)}"
AGENT_SANDBOX_IMAGE_TAG="${AGENT_SANDBOX_IMAGE_TAG:?AGENT_SANDBOX_IMAGE_TAG is required}"
AGENT_SANDBOX_IMAGE_REPO="${AGENT_SANDBOX_IMAGE_REPO:-registry.k8s.io/agent-sandbox/agent-sandbox-controller}"
AGENT_SANDBOX_NAMESPACE="${AGENT_SANDBOX_NAMESPACE:-agent-sandbox-system}"

# --- Install ---
log_info "Installing agent-sandbox controller via Helm..."
log_info "  Chart: ${AGENT_SANDBOX_CHART}"
log_info "  Image: ${AGENT_SANDBOX_IMAGE_REPO}:${AGENT_SANDBOX_IMAGE_TAG}"

helm upgrade --install agent-sandbox "${AGENT_SANDBOX_CHART}" \
    --set image.repository="${AGENT_SANDBOX_IMAGE_REPO}" \
    --set image.tag="${AGENT_SANDBOX_IMAGE_TAG}" \
    --wait --timeout 120s

# --- Verify ---
wait_for_resource "deployment/agent-sandbox-controller" "${AGENT_SANDBOX_NAMESPACE}" "Available" 120

log_info "Agent sandbox controller installed successfully."
