#!/usr/bin/env bats
# Regression coverage for the `curl -fsSL ... | sudo bash` stdin/TTY bug:
# the installer's own source text arriving over stdin must never be
# consumed as answers to its interactive prompts, and confirm()/prompt_read
# must read from the controlling terminal instead. See lib/common.sh
# (wgvpn_init_tty, prompt_read, confirm) and install.sh's wizard.

setup() {
	load 'test_helper.bash'
	PROBE="${REPO_ROOT}/tests/fixtures/interactive_probe.sh"
	HARNESS="${REPO_ROOT}/tests/pty_harness.py"
	export WGVPN_TEST_LIB_DIR="${REPO_ROOT}/lib"
	ANSWERS="$(mktemp)"
}

teardown() {
	rm -f -- "$ANSWERS"
}

run_pty() {
	# $1 = answers (one per line), remaining args passed through to the harness
	printf '%s\n' "$1" >"$ANSWERS"
	shift
	run python3 "$HARNESS" --script "$PROBE" --answers-file "$ANSWERS" "$@"
}

@test "A: installer source over stdin is never consumed as a prompt answer" {
	run_pty "51820
1.1.1.1
y"
	[ "$status" -eq 0 ]
	[[ "$output" != *"comment-line-after"* ]]
	[[ "$output" == *"GOT_PORT=51820"* ]]
}

@test "B: port prompt receives the real terminal answer, not script source" {
	run_pty "51820
1.1.1.1
y"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_PORT=51820"* ]]
}

@test "C: pressing Enter (blank answer) keeps the documented default" {
	run_pty "

y"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_PORT=51820"* ]]
	[[ "$output" == *"GOT_DNS=1.1.1.1"* ]]
}

@test "D: confirm() reads from the controlling terminal when stdin is piped script" {
	run_pty "51820
1.1.1.1
n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_CONFIRM=no"* ]]

	run_pty "51820
1.1.1.1
y"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_CONFIRM=yes"* ]]
}

@test "E: with no controlling terminal at all, the probe fails fast instead of hanging" {
	run python3 "$HARNESS" --script "$PROBE" --no-tty --timeout 10
	[ "$status" -ne 0 ]
	[ "$status" -ne 124 ]  # must not be our own timeout/hang sentinel
	[[ "$output" == *"no controlling terminal is available"* ]]
}

@test "F: non-interactive install.sh parsing is unaffected (no prompt_read reached)" {
	run bash "${REPO_ROOT}/install.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--non-interactive"* ]]
}
