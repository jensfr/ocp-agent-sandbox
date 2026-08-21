#!/usr/bin/env bats
# Smoke test: proves the full stack works end-to-end.
# Creates a sandbox, execs a command, verifies output, cleans up.

load helpers/setup

@test "smoke: full stack create-exec-delete works" {
    create_sandbox "${SANDBOX_NAME}"
    run exec_in_sandbox "${SANDBOX_NAME}" echo "ok"
    delete_sandbox "${SANDBOX_NAME}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}
