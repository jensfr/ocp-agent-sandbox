#!/bin/bash
set -euo pipefail

echo "Installing agent-sandbox controller..."

AGENT_SANDBOX_IMAGE_REPO="${AGENT_SANDBOX_IMAGE_REPO:-registry.k8s.io/agent-sandbox/agent-sandbox-controller}"
AGENT_SANDBOX_IMAGE_TAG="${AGENT_SANDBOX_IMAGE_TAG:?AGENT_SANDBOX_IMAGE_TAG is required}"

if [[ -n "${AGENT_SANDBOX_HELM_CHART:-}" ]]; then
    CHART="${AGENT_SANDBOX_HELM_CHART}"
else
    # Use upstream release manifest
    AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.5.5}"
    MANIFEST_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
    echo "Applying agent-sandbox manifest from ${MANIFEST_URL}..."
    oc apply -f "${MANIFEST_URL}"
    oc -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=300s
    echo "Agent-sandbox controller installed via manifest."
    exit 0
fi

echo "Installing agent-sandbox via Helm chart: ${CHART}"
echo "Image: ${AGENT_SANDBOX_IMAGE_REPO}:${AGENT_SANDBOX_IMAGE_TAG}"

helm upgrade --install agent-sandbox "${CHART}" \
    --set image.repository="${AGENT_SANDBOX_IMAGE_REPO}" \
    --set image.tag="${AGENT_SANDBOX_IMAGE_TAG}" \
    --wait --timeout 120s

oc -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s

echo "Agent-sandbox controller installed successfully."
