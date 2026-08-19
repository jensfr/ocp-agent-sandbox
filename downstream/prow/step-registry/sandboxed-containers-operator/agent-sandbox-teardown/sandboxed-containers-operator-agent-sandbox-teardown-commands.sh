#!/bin/bash
set -euo pipefail

echo "Tearing down agent-sandbox and OpenShell..."

# Clean up sandboxes first
oc delete sandboxes --all -A --timeout=30s 2>/dev/null || true

# Uninstall OpenShell gateway
helm uninstall openshell -n openshell 2>/dev/null || true

# Uninstall agent-sandbox
helm uninstall agent-sandbox 2>/dev/null || true
oc delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.5/manifest.yaml" 2>/dev/null || true

# Clean up namespace
oc delete namespace openshell --wait=false 2>/dev/null || true

echo "Teardown complete."
