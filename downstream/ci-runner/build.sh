#!/usr/bin/env bash
# Build and push the CI runner image.
# Run from the repo root: downstream/ci-runner/build.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(mktemp -d)"
IMAGE="${CI_RUNNER_IMAGE:-quay.io/jensfr/agent-sandbox-ci-runner:latest}"

trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "=== Building CI runner image: ${IMAGE} ==="

# --- Copy test scripts ---
cp -r "${REPO_ROOT}/downstream" "${BUILD_DIR}/downstream"

# --- Copy Dockerfile ---
cp "${REPO_ROOT}/downstream/ci-runner/Dockerfile" "${BUILD_DIR}/Dockerfile"

# --- Get openshell CLI binary (linux/amd64) ---
if [[ -f "${OPENSHELL_BIN:-}" ]]; then
    cp "${OPENSHELL_BIN}" "${BUILD_DIR}/openshell"
elif command -v openshell &>/dev/null && [[ "$(file "$(command -v openshell)")" == *"x86-64"* ]]; then
    cp "$(command -v openshell)" "${BUILD_DIR}/openshell"
else
    echo "Downloading openshell CLI from gateway image..."
    podman create --name openshell-extract ghcr.io/nvidia/openshell/gateway:latest 2>/dev/null || true
    podman cp openshell-extract:/usr/local/bin/openshell "${BUILD_DIR}/openshell" 2>/dev/null || {
        echo "ERROR: Could not get openshell binary."
        echo "Set OPENSHELL_BIN=/path/to/openshell-linux-amd64 and re-run."
        exit 1
    }
    podman rm openshell-extract 2>/dev/null || true
fi

# --- Pre-compile Rust e2e binary (if OpenShell repo available) ---
OPENSHELL_REPO="${OPENSHELL_REPO:-${REPO_ROOT}/../OpenShell}"
if [[ -d "${OPENSHELL_REPO}/e2e/rust" ]]; then
    echo "Compiling Rust e2e tests (linux/amd64)..."
    cd "${OPENSHELL_REPO}/e2e/rust"

    if [[ "$(uname -m)" == "x86_64" ]]; then
        cargo test --features e2e-kubernetes --no-run --message-format=json 2>/dev/null \
            | grep '"executable"' | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin)['executable'])" \
            | xargs -I{} cp {} "${BUILD_DIR}/openshell-e2e"
    else
        echo "Cross-compiling Rust for x86_64..."
        CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
        cargo test --features e2e-kubernetes --no-run --target x86_64-unknown-linux-gnu \
            --message-format=json 2>/dev/null \
            | grep '"executable"' | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin)['executable'])" \
            | xargs -I{} cp {} "${BUILD_DIR}/openshell-e2e" 2>/dev/null || {
                echo "WARNING: Rust cross-compilation failed. Building image without e2e binary."
                touch "${BUILD_DIR}/openshell-e2e"
            }
    fi
    cd "${REPO_ROOT}"
else
    echo "WARNING: OpenShell repo not found at ${OPENSHELL_REPO}. Building without e2e binary."
    touch "${BUILD_DIR}/openshell-e2e"
fi

# --- Build image ---
echo "Building image..."
podman build --platform linux/amd64 -t "${IMAGE}" "${BUILD_DIR}"

echo ""
echo "=== Image built: ${IMAGE} ==="
echo ""
echo "To push: podman push ${IMAGE}"
echo "To deploy: oc apply -f downstream/ci-runner/manifests/"
echo "To test: oc create job --from=cronjob/agent-sandbox-nightly-regression test-run -n agent-sandbox-ci"
