# Downstream CI Prototype: Agent Sandbox + OpenShell + Kata

Prototype CI artifacts for testing agent sandbox with OpenShell and kata
containers on OpenShift. Each subdirectory maps to its target repo for
later extraction:

| Directory   | Target repo                              | Target path                  |
|-------------|------------------------------------------|------------------------------|
| `test/`     | `openshift/sandboxed-containers-operator`| `test/agent-sandbox/`        |
| `helm/`     | `confidential-devhub/charts`             | chart root                   |
| `scripts/`  | `openshift/release`                      | step registry                |

No cross-directory imports — each area must work standalone after extraction.

## Quick start

Run BATS tests against a cluster with the full stack deployed:

```bash
export KUBECONFIG=/path/to/kubeconfig
make test-openshell-kata
```

Install the stack (assumes OSC operator + KataConfig already present):

```bash
export AGENT_SANDBOX_IMAGE_TAG=v0.3.10
export OPENSHELL_IMAGE=registry.example.com/openshell-gateway
export OPENSHELL_IMAGE_TAG=latest
make install-agent-sandbox
make install-openshell
```

Tear down:

```bash
make teardown
```

## Prerequisites

- OpenShift cluster with OSC operator installed and KataConfig created
- `kubectl` / `oc` configured with cluster admin access
- `helm` v3+
- `bats` (bats-core 1.5+) for running tests
- `openshell` CLI (optional — tests fall back to kubectl if not found)
