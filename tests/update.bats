#!/usr/bin/env bats

setup() {
	load 'test_helper.bash'
	source "${REPO_ROOT}/lib/common.sh"
	source "${REPO_ROOT}/lib/backup.sh"
	source "${REPO_ROOT}/lib/wireguard.sh"
	source "${REPO_ROOT}/lib/update.sh"
}

@test "version_compare equal versions" {
	run version_compare "1.0.0" "1.0.0"
	[ "$output" = "0" ]
}

@test "version_compare a less than b" {
	run version_compare "1.0.0" "1.2.0"
	[ "$output" = "-1" ]
}

@test "version_compare a greater than b" {
	run version_compare "2.0.0" "1.9.9"
	[ "$output" = "1" ]
}

@test "version_compare handles differing segment counts" {
	run version_compare "1.0" "1.0.1"
	[ "$output" = "-1" ]
	run version_compare "1.0.0" "1.0"
	[ "$output" = "0" ]
}

@test "version_compare handles double-digit versions correctly (not lexicographic)" {
	run version_compare "1.9.0" "1.10.0"
	[ "$output" = "-1" ]
}
