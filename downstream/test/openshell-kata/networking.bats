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

@test "networking: nftables module is active with references" {
    run exec_in_sandbox "${SANDBOX_NAME}" cat /proc/modules
    [ "$status" -eq 0 ]
    # nf_tables should have active references (typically 30+) when OpenShell networking is set up
    local nft_line
    nft_line=$(echo "$output" | grep "^nf_tables " || true)
    [[ -n "${nft_line}" ]]
    # Third field is the reference count — should be > 0
    local refcount
    refcount=$(echo "${nft_line}" | awk '{print $3}')
    (( refcount > 0 ))
}
