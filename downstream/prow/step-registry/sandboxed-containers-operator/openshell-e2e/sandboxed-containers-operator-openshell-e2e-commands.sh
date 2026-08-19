#!/bin/bash
set -euo pipefail

echo "Running upstream OpenShell Rust e2e tests..."

OPENSHELL_E2E_FEATURES="${OPENSHELL_E2E_FEATURES:-e2e-kubernetes}"
OPENSHELL_E2E_TEST="${OPENSHELL_E2E_TEST:-}"
NAMESPACE="openshell"

# Install Rust if not present
if ! command -v cargo &>/dev/null; then
    echo "Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "${HOME}/.cargo/env"
fi

# Install openshell CLI if not present
if ! command -v openshell &>/dev/null; then
    echo "Installing openshell CLI..."
    OPENSHELL_CLI_VERSION="${OPENSHELL_CLI_VERSION:-latest}"
    curl -sL "https://github.com/nvidia/openshell/releases/${OPENSHELL_CLI_VERSION}/download/openshell-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/ openshell || true
fi

# Clone OpenShell repo for test sources
OPENSHELL_REPO=$(mktemp -d)
git clone --depth 1 https://github.com/nvidia/openshell.git "${OPENSHELL_REPO}"

# Register the gateway
GATEWAY_POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}')
echo "Gateway pod: ${GATEWAY_POD}"

# Start health port-forward
HEALTH_PORT=8081
oc -n "${NAMESPACE}" port-forward "pod/${GATEWAY_POD}" "${HEALTH_PORT}:health" &>/tmp/pf-health.log &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

# Wait for port-forward
elapsed=0
while (( elapsed < 15 )); do
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${HEALTH_PORT}/healthz" 2>/dev/null; then
        break
    fi
    sleep 1
    (( elapsed++ ))
done

# Build test filter
test_args=()
if [[ -n "${OPENSHELL_E2E_TEST}" ]]; then
    test_args+=(--test "${OPENSHELL_E2E_TEST}")
fi

echo "Running cargo test with features: ${OPENSHELL_E2E_FEATURES}"
cd "${OPENSHELL_REPO}/e2e/rust"

OPENSHELL_BIN="$(command -v openshell)" \
OPENSHELL_E2E_HEALTH_PORT="${HEALTH_PORT}" \
    cargo test \
        --features "${OPENSHELL_E2E_FEATURES}" \
        ${test_args[@]+"${test_args[@]}"} \
        -- --nocapture

echo "Upstream OpenShell e2e tests completed."
