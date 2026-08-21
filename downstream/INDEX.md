# Agent Sandbox Downstream CI — Master Index

**Last updated:** 2026-08-21
**Branch:** [`downstream-ci-prototype`](https://github.com/jensfr/ocp-agent-sandbox/tree/downstream-ci-prototype)

## Artifacts

### Code & Tests (on branch)

| What | Path | Status |
|------|------|--------|
| BATS integration tests (14 tests) | `downstream/test/openshell-kata/` | Validated 14/14 |
| Upstream OpenShell Rust e2e (80 tests) | via `downstream/scripts/run-openshell-e2e.sh` | Validated 80/80 |
| BATS test helpers (openshell CLI + kubectl fallback) | `downstream/test/openshell-kata/helpers/setup.bash` | Done |
| OpenShell gateway Helm chart (SCC, SAs, config, PVs) | `downstream/helm/openshell-gateway/` | Lints clean, templates verified |
| Prow step registry (5 steps + workflow) | `downstream/prow/step-registry/` | Draft, ready for review |
| Prow job config (3 strategies × 2 platforms) | `downstream/prow/config/` | Draft, Strategy 1 ready |
| Install scripts (agent-sandbox, openshell, separate) | `downstream/scripts/install-*.sh` | Tested on virtlab725 |
| Test runner scripts (BATS, upstream e2e) | `downstream/scripts/run-*.sh` | Tested on virtlab725 |
| Teardown script | `downstream/scripts/teardown.sh` | Tested |
| Controller bug fix backport (RHBAS-19) | `controllers/sandbox_controller.go` | Verified, 5/5 stop/start |
| Root Makefile target | `Makefile` (`test-downstream-openshell`) | Done |

### Documentation (gists)

| Document | URL | Purpose |
|----------|-----|---------|
| CI methodology & design | [gist](https://gist.github.com/jensfr/383c8dc6ca55f31327670ce260b4c0e2) | Architecture, decisions, rationale |
| CI strategy (3-strategy model) | [gist (same, appended)](https://gist.github.com/jensfr/383c8dc6ca55f31327670ce260b4c0e2) | Regression / next-release / integration |
| Test matrix (all controller variants) | [gist](https://gist.github.com/jensfr/8f22b2dceecf96ffdbac9b60083df563) | 4 controllers × 3 test suites |
| BATS test report (rendered) | [gist](https://gist.github.com/jensfr/46a4b279f471b12f1ad6afb664da769a) | 14/14 pass, timing data |
| OpenShell e2e test skill | [gist](https://gist.github.com/jensfr/f81b757877a8dc9f02946fe09f25f256) | How to run upstream tests manually |

### JIRA

| Ticket | Summary | Status |
|--------|---------|--------|
| [RHBAS-19](https://redhat.atlassian.net/browse/RHBAS-19) | Stale Suspended condition after sandbox resume | Open — fix backported and verified, recommend rebase to v0.5.5 |

### Key Findings

1. **v0.5.5 rebase is clean** — `git merge v0.5.5` produces 6 conflicts, none in Go source. 94/94 tests pass.
2. **Suspended condition bug** (RHBAS-19) — affects any user doing stop/start (~1/3 failure rate). Fixed upstream in PR #1150. Manual backport verified.
3. **OpenShell sandbox names limited to 19 chars** — tests must use short names.
4. **Kata config drop-ins** — kata reads ALL files in `config.d/` regardless of extension. Stale `.bak` files silently override the initrd.
5. **Three CI strategies needed** — regression (ready now), next-release (needs contracts), forward integration (needs contracts).

### Target Repos (for extraction)

| Component | Target Repo | Target Path |
|-----------|-------------|-------------|
| BATS tests | `openshift/sandboxed-containers-operator` | `test/agent-sandbox/` |
| Helm chart | `confidential-devhub/charts` | chart root |
| Prow steps + config | `openshift/release` | `ci-operator/step-registry/` + `ci-operator/config/` |

### How to Reproduce

```bash
git clone https://github.com/jensfr/ocp-agent-sandbox.git
cd ocp-agent-sandbox && git checkout downstream-ci-prototype
export KUBECONFIG=~/kubeconfig.virtlab725

# Verify cluster prerequisites
make -C downstream preflight

# Run BATS integration tests (14 tests, ~2.5 min)
make -C downstream test-openshell-kata

# Run upstream OpenShell Rust e2e tests (80 tests, ~6 min)
make -C downstream test-openshell-e2e

# Run all 94 tests
make -C downstream test-all
```
