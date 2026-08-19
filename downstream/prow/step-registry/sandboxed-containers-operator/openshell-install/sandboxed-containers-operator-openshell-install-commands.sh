#!/bin/bash
set -euo pipefail

echo "Installing OpenShell gateway..."

OPENSHELL_IMAGE="${OPENSHELL_IMAGE:-ghcr.io/nvidia/openshell/gateway}"
OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-latest}"
OPENSHELL_RUNTIME_CLASS="${OPENSHELL_RUNTIME_CLASS:-kata}"
OPENSHELL_LOCAL_STORAGE="${OPENSHELL_LOCAL_STORAGE:-true}"
NAMESPACE="openshell"

# Pre-flight: verify kata RuntimeClass exists
if ! oc get runtimeclass "${OPENSHELL_RUNTIME_CLASS}" &>/dev/null; then
    echo "ERROR: RuntimeClass '${OPENSHELL_RUNTIME_CLASS}' not found. Is KataConfig created?"
    exit 1
fi

# Pre-flight: verify OSC operator
if ! oc get namespace openshift-sandboxed-containers-operator &>/dev/null; then
    echo "ERROR: OSC operator namespace not found."
    exit 1
fi

# Check for stale kata config drop-ins
echo "Checking for stale kata config drop-ins on nodes..."
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Node: ${node}"
    oc debug "node/${node}" -- chroot /host ls -la /etc/kata-containers/config.d/ 2>/dev/null || true
done

if [[ -n "${OPENSHELL_HELM_CHART:-}" ]]; then
    CHART="${OPENSHELL_HELM_CHART}"
else
    # Clone upstream OpenShell and use its Helm chart
    OPENSHELL_REPO_DIR=$(mktemp -d)
    git clone --depth 1 https://github.com/nvidia/openshell.git "${OPENSHELL_REPO_DIR}"
    CHART="${OPENSHELL_REPO_DIR}/deploy/helm/openshell"
fi

echo "Installing OpenShell gateway via Helm..."
echo "  Chart: ${CHART}"
echo "  Image: ${OPENSHELL_IMAGE}:${OPENSHELL_IMAGE_TAG}"
echo "  RuntimeClass: ${OPENSHELL_RUNTIME_CLASS}"

# Create namespace and SCC
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "${NAMESPACE}"

helm upgrade --install openshell "${CHART}" \
    --namespace "${NAMESPACE}" \
    --set image.tag="${OPENSHELL_IMAGE_TAG}" \
    --set server.defaultRuntimeClassName="${OPENSHELL_RUNTIME_CLASS}" \
    --set server.disableTls=true \
    --set podSecurityContext.fsGroup=null \
    --set securityContext.runAsUser=null \
    --wait --timeout 300s

# Verify gateway is running
oc -n "${NAMESPACE}" rollout status statefulset/openshell --timeout=120s

# Set up local-path provisioner if needed
if [[ "${OPENSHELL_LOCAL_STORAGE}" == "true" ]]; then
    echo "Setting up local-path-provisioner..."
    oc apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml || true
    oc patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
    oc adm policy add-scc-to-user privileged -z local-path-provisioner-service-account -n local-path-storage || true
    oc adm policy add-scc-to-user hostmount-anyuid -z local-path-provisioner-service-account -n local-path-storage || true

    for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        oc debug "node/${node}" -- chroot /host bash -c \
            "mkdir -p /opt/local-path-provisioner && chmod 777 /opt/local-path-provisioner && chcon -R system_u:object_r:container_file_t:s0 /opt/local-path-provisioner" || true
    done
fi

echo "OpenShell gateway installed successfully."
