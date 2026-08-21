# Prow Step Registry and Job Config (Draft)

Draft Prow step registry entries and ci-operator job config for agent-sandbox
downstream CI. These files are staged here for review before submitting as a PR
to `openshift/release`.

## CI Strategy

Agent Sandbox, OpenShell, and OSC are three independently releasing products,
each with its own release cycle. Kata upstream adds a fourth axis. Testing every
combination doesn't scale — instead we define three CI strategies, each answering
a different question:

### Strategy 1: Regression — "Did our change break things?"

```
Agent Sandbox HEAD (Konflux-built)  ← the moving part
× OpenShell pinned known-good      ← fixed
× OSC pinned known-good            ← fixed
× Kata RPM pinned known-good       ← fixed
```

- **Trigger:** on every Konflux build (postsubmit) or PR
- **Failures are:** blockers — our change broke something
- **Platforms:** bare-metal + AWS

### Strategy 2: Next-release compatibility — "Will the versions we ship together work?"

```
Agent Sandbox RC
× OpenShell RC (coordinated with NVIDIA)
× OSC RC
× Kata RPM RC
```

- **Trigger:** weekly or milestone-gated
- **Failures are:** release blockers — the planned combination doesn't work
- **Platforms:** bare-metal (primary), AWS (secondary)
- **Requires:** agreement with OpenShell team on which RC to test

### Strategy 3: Forward integration — "Are projects diverging?"

```
Agent Sandbox HEAD
× OpenShell HEAD (latest)
× OSC latest internal build
× Kata latest scratch build
```

- **Trigger:** nightly
- **Failures are:** warnings, not blockers — early signal of divergence
- **Platforms:** bare-metal only (cost containment)
- **Requires:** no coordination — uses latest of everything

### Prerequisite: Compatibility contracts

Before implementing strategies 2 and 3, we need agreement with OpenShell (Ran)
and OSC on:

- Which OpenShell release supports which Agent Sandbox release?
- Does OpenShell commit to testing against our RC before we ship?
- Who owns the HEAD×HEAD nightly — us, OpenShell, or shared?

Strategy 1 (regression) is ready to deploy now. Strategies 2 and 3 are
parameterized and ready — they just need the version pins filled in once
contracts are agreed.

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
Prow job trigger (postsubmit / cron / manual)
  |
  v
sandboxed-containers-operator-e2e-agent-sandbox workflow:
  pre:
    1. sandboxed-containers-operator-pre (existing: get kata RPM, create env configmap)
    2. sandboxed-containers-operator-agent-sandbox-install (NEW)
    3. sandboxed-containers-operator-openshell-install (NEW)
  test:
    4. sandboxed-containers-operator-agent-sandbox-test (NEW: BATS, 14 tests)
    5. sandboxed-containers-operator-openshell-e2e (NEW: upstream Rust e2e, 80 tests)
  post:
    6. sandboxed-containers-operator-agent-sandbox-teardown (NEW)
```

## Target environments

Two platforms matching customer #0 environments:

| Platform | Cluster Profile | Instance Type | Storage | Strategies |
|----------|----------------|--------------|---------|------------|
| Bare metal | `bare-metal` | N/A | local-path-provisioner | 1, 2, 3 |
| AWS (nested virt) | `aws` | m5.metal / c5.metal | EBS (dynamic) | 1, 2 |

The workflow, scripts, and tests are identical across both — only `cluster_profile`
and instance type differ.

## Before submitting the PR

1. Review with OSC CI working group (Wainer Moschetta, Tom Buskey)
2. Verify `cluster_profile` names match available CI pools for bare-metal and AWS
3. Confirm AWS instance type supports nested virt (m5.metal or c5.metal)
4. Pin known-good versions for Strategy 1 (current validated: OpenShell 0.0.105, kata 3.31.0-5)
5. Agree on compatibility contracts with OpenShell team for Strategy 2
6. Decide on triggers: postsubmit for Strategy 1, weekly cron for Strategy 2, nightly for Strategy 3
7. The `upi-installer` base image may need Rust toolchain for the openshell-e2e step
