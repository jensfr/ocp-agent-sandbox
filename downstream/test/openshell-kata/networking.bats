#!/usr/bin/env bats
# Networking test: verify OpenShell's transparent proxy networking
# is active inside the kata VM (veth pairs + nftables rules).

load helpers/setup

setup_file() {
    create_sandbox "${SANDBOX_NAME}"
}

teardown_file() {
    cleanup_sandbox "${SANDBOX_NAME}"
}

@test "networking: veth pair exists inside sandbox" {
    run exec_in_sandbox "${SANDBOX_NAME}" ip link show type veth
    [ "$status" -eq 0 ]
    [[ "$output" == *"veth"* ]]
}

@test "networking: nftables has active rules" {
    run exec_in_sandbox "${SANDBOX_NAME}" nft list ruleset
    [ "$status" -eq 0 ]
    [[ "$output" == *"table"* ]]
}
