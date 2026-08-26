#!/usr/bin/env bash
# Track CI run history in a ConfigMap for cross-run comparison.
# Source this file after common.sh; do not execute directly.

HISTORY_CM="ci-run-history"
HISTORY_NS="agent-sandbox-ci"

# Save current run results to ConfigMap
save_run_state() {
    local results_json="$1"  # JSON string with per-variant results

    # Get upstream HEAD SHA from the image tag
    local upstream_sha
    upstream_sha=$(kubectl get deployment agent-sandbox-controller -n agent-sandbox-system \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oE '[a-f0-9]{7,}' | tail -1 || true)

    # Store in ConfigMap (create or update)
    kubectl create configmap "${HISTORY_CM}" -n "${HISTORY_NS}" \
        --from-literal="last-results=${results_json}" \
        --from-literal="last-upstream-sha=${upstream_sha}" \
        --from-literal="last-run-time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
}

# Load previous run state from ConfigMap
load_previous_state() {
    PREV_RESULTS=$(kubectl get configmap "${HISTORY_CM}" -n "${HISTORY_NS}" \
        -o jsonpath='{.data.last-results}' 2>/dev/null || true)
    PREV_UPSTREAM_SHA=$(kubectl get configmap "${HISTORY_CM}" -n "${HISTORY_NS}" \
        -o jsonpath='{.data.last-upstream-sha}' 2>/dev/null || true)
    PREV_RUN_TIME=$(kubectl get configmap "${HISTORY_CM}" -n "${HISTORY_NS}" \
        -o jsonpath='{.data.last-run-time}' 2>/dev/null || true)
}

# Get new upstream commits since last run
get_upstream_changelog() {
    local current_sha="$1"
    local previous_sha="${PREV_UPSTREAM_SHA}"

    if [[ -z "${previous_sha}" || -z "${current_sha}" || "${previous_sha}" == "${current_sha}" ]]; then
        echo ""
        return
    fi

    # Query GitHub API for commits between the two SHAs
    local commits
    commits=$(curl -sf "https://api.github.com/repos/kubernetes-sigs/agent-sandbox/compare/${previous_sha}...${current_sha}" 2>/dev/null | \
        python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    commits = data.get('commits', [])
    if not commits:
        sys.exit(0)
    print(f'{len(commits)} new commit(s) since {sys.argv[1][:7]}:')
    for c in commits[-10:]:  # last 10
        sha = c['sha'][:7]
        msg = c['commit']['message'].split('\n')[0][:72]
        print(f'  {sha} {msg}')
    if len(commits) > 10:
        print(f'  ... and {len(commits)-10} more')
except:
    pass
" "${previous_sha}" 2>/dev/null || true)

    echo "${commits}"
}

# Compare current results with previous run
compare_results() {
    local current_json="$1"

    if [[ -z "${PREV_RESULTS}" ]]; then
        echo "First run — no previous results to compare."
        return
    fi

    python3 -c "
import json, sys

try:
    lines = sys.stdin.read().split('\n---SEPARATOR---\n')
    current = json.loads(lines[0])
    previous = json.loads(lines[1])
except Exception as e:
    print(f'Could not parse results for comparison: {e}')
    sys.exit(0)

changes = []
stable_failures = []

for variant in current:
    curr = current[variant]
    prev = previous.get(variant, {})

    curr_failed = set(curr.get('failed_tests', []))
    prev_failed = set(prev.get('failed_tests', []))

    if not prev:
        if curr_failed:
            changes.append(f'  {variant}: NEW — {len(curr_failed)} failure(s)')
        continue

    new_failures = curr_failed - prev_failed
    fixed = prev_failed - curr_failed
    still_failing = curr_failed & prev_failed

    if new_failures:
        for t in sorted(new_failures):
            changes.append(f'  {variant}: NEW FAILURE — {t}')
    if fixed:
        for t in sorted(fixed):
            changes.append(f'  {variant}: FIXED — {t}')
    if still_failing:
        for t in sorted(still_failing):
            stable_failures.append(f'  {variant}: still failing — {t}')

if changes:
    print('Changes since last run:')
    print('\n'.join(changes))
else:
    print('No changes in test results since last run.')

if stable_failures:
    print('Known stable failures:')
    print('\n'.join(stable_failures))
" <<COMPARE_EOF 2>/dev/null || echo "Could not compare results."
${current_json}
---SEPARATOR---
${PREV_RESULTS}
COMPARE_EOF
}
