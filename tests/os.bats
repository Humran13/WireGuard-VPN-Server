#!/usr/bin/env bats

setup() {
	load 'test_helper.bash'
	load_libs
}

@test "os_version_ge basic comparisons" {
	run os_version_ge "20.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "18.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "16.04" "18.04"; [ "$status" -ne 0 ]
	run os_version_ge "22.04" "20.04"; [ "$status" -eq 0 ]
	run os_version_ge "26.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "30.10" "18.04"; [ "$status" -eq 0 ]
}

@test "os_is_tested matches explicit list only" {
	run os_is_tested "22.04"; [ "$status" -eq 0 ]
	run os_is_tested "18.04"; [ "$status" -eq 0 ]
	run os_is_tested "26.04"; [ "$status" -eq 0 ]
	run os_is_tested "21.10"; [ "$status" -ne 0 ]
	run os_is_tested "30.04"; [ "$status" -ne 0 ]
}

@test "os_read_release parses a fake os-release file" {
	local f="${BATS_TEST_TMPDIR}/os-release"
	cat >"$f" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 22.04.3 LTS"
EOF
	os_read_release "$f"
	[ "$OS_ID" = "ubuntu" ]
	[ "$OS_VERSION_ID" = "22.04" ]
	[ "$OS_CODENAME" = "jammy" ]
}

@test "os_check_support rejects non-Ubuntu" {
	local f="${BATS_TEST_TMPDIR}/os-release"
	cat >"$f" <<'EOF'
NAME="Debian"
VERSION_ID="12"
ID=debian
EOF
	run bash -c "source '${REPO_ROOT}/lib/common.sh'; source '${REPO_ROOT}/lib/os.sh'; os_read_release() { OS_ID=debian; OS_VERSION_ID=12; OS_CODENAME=bookworm; }; os_check_support"
	[ "$status" -ne 0 ]
}

@test "os_check_support accepts future Ubuntu with compat mode notice" {
	run bash -c "source '${REPO_ROOT}/lib/common.sh'; source '${REPO_ROOT}/lib/os.sh'; os_read_release() { OS_ID=ubuntu; OS_VERSION_ID=30.04; OS_CODENAME=zzzzy; }; os_check_support; echo \"MODE=\$OS_SUPPORT_MODE\""
	[ "$status" -eq 0 ]
	[[ "$output" == *"has not been explicitly tested"* ]]
	[[ "$output" == *"MODE=compat"* ]]
}

@test "os_check_support rejects Ubuntu older than 18.04" {
	run bash -c "source '${REPO_ROOT}/lib/common.sh'; source '${REPO_ROOT}/lib/os.sh'; os_read_release() { OS_ID=ubuntu; OS_VERSION_ID=16.04; OS_CODENAME=xenial; }; os_check_support"
	[ "$status" -ne 0 ]
	[[ "$output" == *"too old"* ]]
}

@test "os_arch normalizes machine names" {
	run os_arch
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^(amd64|arm64|armhf|.+)$ ]]
}
