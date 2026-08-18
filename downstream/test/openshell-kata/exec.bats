#!/usr/bin/env bats
# Exec test: create a persistent sandbox, exec into it, verify output.

load helpers/setup

setup() {
    create_sandbox "${SANDBOX_NAME}"
}

teardown() {
    cleanup_sandbox "${SANDBOX_NAME}"
}

@test "exec: run command inside sandbox and verify output" {
    run exec_in_sandbox "${SANDBOX_NAME}" echo "hello from kata"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello from kata"* ]]
}

@test "exec: run multiple commands sequentially" {
    run exec_in_sandbox "${SANDBOX_NAME}" echo "first"
    [ "$status" -eq 0 ]
    [[ "$output" == *"first"* ]]

    run exec_in_sandbox "${SANDBOX_NAME}" echo "second"
    [ "$status" -eq 0 ]
    [[ "$output" == *"second"* ]]
}
