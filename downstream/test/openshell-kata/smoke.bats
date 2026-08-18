#!/usr/bin/env bats
# Smoke test: proves the full stack works end-to-end.
# OpenShell CLI -> gateway -> agent sandbox controller -> kata VM -> command output

load helpers/setup

@test "smoke: sandbox create with echo command succeeds" {
    run create_sandbox_run "${SANDBOX_NAME}" echo "ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}
