# Prow Step Registry and Job Config (Draft)

Draft Prow step registry entries and ci-operator job config for agent-sandbox
downstream CI. These files are staged here for review before submitting as a PR
to `openshift/release`.

## Target locations in openshift/release

| Source file | Target in openshift/release |
|-------------|----------------------------|
| `step-registry/sandboxed-containers-operator/agent-sandbox-install/` | `ci-operator/step-registry/sandboxed-containers-operator/agent-sandbox-install/` |
| `step-registry/sandboxed-containers-operator/openshell-install/` | `ci-operator/step-registry/sandboxed-containers-operator/openshell-install/` |
| `step-registry/sandboxed-containers-operator/agent-sandbox-test/` | `ci-operator/step-registry/sandboxed-containers-operator/agent-sandbox-test/` |
| `step-registry/sandboxed-containers-operator/openshell-e2e/` | `ci-operator/step-registry/sandboxed-containers-operator/openshell-e2e/` |
| `step-registry/sandboxed-containers-operator/agent-sandbox-teardown/` | `ci-operator/step-registry/sandboxed-containers-operator/agent-sandbox-teardown/` |
| `step-registry/sandboxed-containers-operator/e2e/agent-sandbox/` | `ci-operator/step-registry/sandboxed-containers-operator/e2e/agent-sandbox/` |
| `config/openshift-kubernetes-sigs-agent-sandbox-main.yaml` | `ci-operator/config/openshift/kubernetes-sigs-agent-sandbox/openshift-kubernetes-sigs-agent-sandbox-main.yaml` |

## Workflow

```
Konflux build (image push)
  |
  v
Prow job trigger (manual or cron)
  |
  v
sandboxed-containers-operator-e2e-agent-sandbox workflow:
  pre:
    1. sandboxed-containers-operator-pre (existing: get kata RPM, create env configmap)
    2. sandboxed-containers-operator-agent-sandbox-install (NEW)
    3. sandboxed-containers-operator-openshell-install (NEW)
  test:
    4. sandboxed-containers-operator-agent-sandbox-test (NEW: BATS)
    5. sandboxed-containers-operator-openshell-e2e (NEW: upstream Rust e2e)
  post:
    6. sandboxed-containers-operator-agent-sandbox-teardown (NEW)
```

## Target environments

Two jobs matching customer #0 environments:

| Job | Cluster Profile | Notes |
|-----|----------------|-------|
| `agent-sandbox-e2e-kata-baremetal` | `bare-metal` | Primary customer #0 environment. Validated on virtlab725. |
| `agent-sandbox-e2e-kata-aws` | `aws` | Secondary customer #0 environment. Needs metal instances (m5.metal/c5.metal) for kata nested virt. `OPENSHELL_LOCAL_STORAGE=false` — AWS has dynamic provisioning. |

The workflow, scripts, and tests are identical across both — only `cluster_profile`
and instance type differ.

## Before submitting the PR

1. Review with OSC CI working group (Wainer Moschetta, Tom Buskey)
2. Verify `cluster_profile` names match available CI pools for bare-metal and AWS
3. Confirm AWS instance type supports nested virt (m5.metal or c5.metal)
4. Update `KATA_RPM_VERSION` and `KATA_RPM_BUILD_TASK` to current values
5. Decide on trigger: `cron` for periodic, or postsubmit for Konflux-triggered
6. The `upi-installer` base image may need Rust toolchain for the openshell-e2e step — check if a custom image is needed
