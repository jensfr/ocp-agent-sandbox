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

## Before submitting the PR

1. Review with OSC CI working group (Wainer Moschetta, Tom Buskey)
2. Verify the `cluster_profile` and `BASE_DOMAIN` match available CI pools
3. Update `KATA_RPM_VERSION` and `KATA_RPM_BUILD_TASK` to current values
4. Decide on trigger: `cron` for periodic, or postsubmit for Konflux-triggered
5. The `upi-installer` base image may need Rust toolchain for the openshell-e2e step — check if a custom image is needed
