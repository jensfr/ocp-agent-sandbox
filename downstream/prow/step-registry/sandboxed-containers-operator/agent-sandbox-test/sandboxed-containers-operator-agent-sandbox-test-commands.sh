#!/bin/bash
set -euo pipefail

echo "Running BATS integration tests..."

# Install bats if not present
if ! command -v bats &>/dev/null; then
    echo "Installing bats-core..."
    git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
    /tmp/bats-core/install.sh /usr/local
fi

if [[ -n "${BATS_TEST_DIR:-}" ]]; then
    TEST_DIR="${BATS_TEST_DIR}"
else
    REPO_DIR=$(mktemp -d)
    git clone --depth 1 https://github.com/openshift/kubernetes-sigs-agent-sandbox.git "${REPO_DIR}"
    TEST_DIR="${REPO_DIR}/downstream/test/openshell-kata"
fi

# Install openshell CLI if not present
if ! command -v openshell &>/dev/null; then
    echo "Installing openshell CLI..."
    OPENSHELL_CLI_VERSION="${OPENSHELL_CLI_VERSION:-latest}"
    curl -sL "https://github.com/nvidia/openshell/releases/${OPENSHELL_CLI_VERSION}/download/openshell-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/ openshell || true
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

echo "Test directory: ${TEST_DIR}"
echo "Artifacts: ${ARTIFACT_DIR}"

bats \
    --report-formatter junit \
    --output "${ARTIFACT_DIR}" \
    --timing \
    "${TEST_DIR}"/*.bats

echo "BATS tests completed. Results in ${ARTIFACT_DIR}"
