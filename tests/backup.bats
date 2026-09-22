#!/usr/bin/env bats

setup() {
	load 'test_helper.bash'
	source "${REPO_ROOT}/lib/common.sh"
	source "${REPO_ROOT}/lib/wireguard.sh"
	source "${REPO_ROOT}/lib/backup.sh"
}

@test "backup_validate accepts a well-formed archive" {
	local stage="${BATS_TEST_TMPDIR}/stage"
	mkdir -p "${stage}/state"
	echo "1.0.0" >"${stage}/VERSION"
	echo '{}' >"${stage}/state/config.json"
	local archive="${BATS_TEST_TMPDIR}/good.tar.gz"
	tar -czf "$archive" -C "$stage" .
	run backup_validate "$archive"
	[ "$status" -eq 0 ]
}

@test "backup_validate rejects archive with path traversal" {
	local stage="${BATS_TEST_TMPDIR}/stage2"
	mkdir -p "${stage}/state" "${BATS_TEST_TMPDIR}/outside"
	echo "1.0.0" >"${stage}/VERSION"
	echo '{}' >"${stage}/state/config.json"
	local archive="${BATS_TEST_TMPDIR}/traversal.tar.gz"
	( cd "$stage" && tar -czf "$archive" VERSION state "../../../../../../etc/passwd" 2>/dev/null || tar -czf "$archive" -C "$stage" . )
	# Craft a traversal archive directly via tar --transform equivalent: add a member named ../evil
	local stage3="${BATS_TEST_TMPDIR}/stage3"
	mkdir -p "$stage3/state" "$stage3/../evil_target"
	echo "1.0.0" >"${stage3}/VERSION"
	echo '{}' >"${stage3}/state/config.json"
	tar -czf "$archive" --transform 's,^,../,' -C "$stage3" VERSION state 2>/dev/null || skip "tar --transform not supported in this environment"
	run backup_validate "$archive"
	[ "$status" -ne 0 ]
}

@test "backup_validate rejects archive missing VERSION marker" {
	local stage="${BATS_TEST_TMPDIR}/stage4"
	mkdir -p "${stage}/state"
	echo '{}' >"${stage}/state/config.json"
	local archive="${BATS_TEST_TMPDIR}/noversion.tar.gz"
	tar -czf "$archive" -C "$stage" .
	run backup_validate "$archive"
	[ "$status" -ne 0 ]
}

@test "backup_validate rejects a non-tar file" {
	local f="${BATS_TEST_TMPDIR}/notarchive.tar.gz"
	echo "not a real archive" >"$f"
	run backup_validate "$f"
	[ "$status" -ne 0 ]
}

@test "backup_validate rejects missing file" {
	run backup_validate "${BATS_TEST_TMPDIR}/does-not-exist.tar.gz"
	[ "$status" -ne 0 ]
}
