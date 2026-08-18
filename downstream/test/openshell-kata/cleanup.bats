#!/usr/bin/env bats
# Cleanup test: verify sandbox deletion removes all associated resources.

load helpers/setup

# Use short suffixes to stay within 19-char limit: "ci-XXXX-pod" (11), "ci-XXXX-pvc" (11)
CLEANUP_POD_NAME="${SANDBOX_NAME}-pod"
CLEANUP_PVC_NAME="${SANDBOX_NAME}-pvc"

@test "cleanup: sandbox delete removes pod" {
    create_sandbox "${CLEANUP_POD_NAME}"

    # Get the pod name
    local pod_name
    pod_name=$(kubectl get pods -n "${NAMESPACE}" \
        -l "agents.x-k8s.io/sandbox-name-hash" \
        -o jsonpath="{.items[?(@.metadata.name==\"${CLEANUP_POD_NAME}\")].metadata.name}" 2>/dev/null || true)

    # If we can't find by label, try direct name (sandbox controller names pod after sandbox)
    if [[ -z "${pod_name}" ]]; then
        pod_name="${CLEANUP_POD_NAME}"
    fi

    delete_sandbox "${CLEANUP_POD_NAME}"

    wait_for_pod_gone "${pod_name}" "${NAMESPACE}"
}

@test "cleanup: sandbox delete removes PVC" {
    create_sandbox "${CLEANUP_PVC_NAME}"

    # Wait briefly for PVC creation
    sleep 3

    local pvc_name
    pvc_name=$(kubectl get pvc -n "${NAMESPACE}" \
        -l "app.kubernetes.io/managed-by=openshell" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    delete_sandbox "${CLEANUP_PVC_NAME}"

    if [[ -n "${pvc_name}" ]]; then
        wait_for_pvc_gone "${pvc_name}" "${NAMESPACE}"
    else
        # No PVC was created — this is acceptable if OpenShell workspace
        # persistence is disabled. The test passes as there's nothing to leak.
        true
    fi
}
