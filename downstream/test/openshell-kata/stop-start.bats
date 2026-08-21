#!/usr/bin/env bats
# Stop/start test: verify sandbox resume works reliably.
# Catches the stale Suspended condition bug (RHBAS-19, upstream #1150).

load helpers/setup

setup_file() {
    create_sandbox "${SANDBOX_NAME}"
}

teardown_file() {
    cleanup_sandbox "${SANDBOX_NAME}"
}

@test "stop-start: exec succeeds after stop and start" {
    if [[ "${USE_OPENSHELL}" != "true" ]]; then
        skip "stop/start requires openshell CLI"
    fi

    openshell sandbox stop "${SANDBOX_NAME}"
    wait_for_sandbox_phase "${SANDBOX_NAME}" "Stopped"
    openshell sandbox start "${SANDBOX_NAME}"
    wait_for_sandbox_phase "${SANDBOX_NAME}" "Ready"
    run exec_in_sandbox "${SANDBOX_NAME}" echo "resumed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resumed"* ]]
}

@test "stop-start: Suspended condition is False after resume" {
    local suspended_status
    suspended_status=$(kubectl get sandbox "default--${SANDBOX_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Suspended")].status}' 2>/dev/null || true)
    # Accept False (fixed controller) or empty (no Suspended condition = old controller)
    [[ "${suspended_status}" != "True" ]]
}

@test "stop-start: three consecutive cycles all succeed" {
    if [[ "${USE_OPENSHELL}" != "true" ]]; then
        skip "stop/start requires openshell CLI"
    fi

    for i in 1 2 3; do
        # Poll until gateway confirms Ready before stopping (avoids race)
        wait_for_sandbox_phase "${SANDBOX_NAME}" "Ready"
        openshell sandbox stop "${SANDBOX_NAME}"
        wait_for_sandbox_phase "${SANDBOX_NAME}" "Stopped"
        openshell sandbox start "${SANDBOX_NAME}"
        wait_for_sandbox_phase "${SANDBOX_NAME}" "Ready"
        run exec_in_sandbox "${SANDBOX_NAME}" echo "cycle-${i}"
        [ "$status" -eq 0 ]
        [[ "$output" == *"cycle-${i}"* ]]
    done
}
