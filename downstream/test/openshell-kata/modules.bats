#!/usr/bin/env bats
# Module verification: confirm kata VM initrd has the kernel modules
# needed for OpenShell's transparent proxy networking.

load helpers/setup

setup_file() {
    create_sandbox "${SANDBOX_NAME}"
}

teardown_file() {
    cleanup_sandbox "${SANDBOX_NAME}"
}

@test "modules: nf_tables is loaded in kata VM" {
    run exec_in_sandbox "${SANDBOX_NAME}" cat /proc/modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"nf_tables"* ]]
}

@test "modules: nft_reject is loaded" {
    run exec_in_sandbox "${SANDBOX_NAME}" cat /proc/modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"nft_reject "* ]]
}

@test "modules: nft_reject_inet is loaded" {
    run exec_in_sandbox "${SANDBOX_NAME}" cat /proc/modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"nft_reject_inet"* ]]
}

@test "modules: veth is loaded" {
    run exec_in_sandbox "${SANDBOX_NAME}" cat /proc/modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"veth"* ]]
}
