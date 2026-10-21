#!/usr/bin/env bats
# Regression coverage for two related production bugs in the interactive
# installer under `curl -fsSL ... | sudo bash`:
#
#   1. Prompts sharing stdin with the piped installer source, so script
#      source lines got consumed as answers instead of real terminal input.
#
#   2. Opening the controlling terminal via a bare `exec 3<>/dev/tty
#      2>/dev/null` permanently redirecting this *process's own stderr* to
#      /dev/null as a side effect (bash applies every redirection on a
#      command-less `exec` persistently, not just for that one attempt) -
#      so every prompt after the first, and every warn()/err() message,
#      silently stopped being displayed even though answers were still
#      read correctly underneath. From a human's perspective this is
#      indistinguishable from the installer hanging.
#
# See lib/common.sh (wgvpn_init_tty, wgvpn_close_tty, prompt_read,
# confirm) and install.sh's wizard.
#
# tests/pty_harness.py drives the probe over a real pty, with fd 0 fed
# from a separate, non-seekable pipe (exactly like `curl | bash`) while
# fd 1/2 are left attached to the pty - so the captured byte stream is
# exactly what a human would have seen on their real terminal, in the
# order it was written, interleaved with typed answers.

setup() {
	load 'test_helper.bash'
	PROBE="${REPO_ROOT}/tests/fixtures/interactive_probe.sh"
	HARNESS="${REPO_ROOT}/tests/pty_harness.py"
	INSTALL_SH="${REPO_ROOT}/install.sh"
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

# All answers for a full pass through the probe, in prompt order.
FULL_ANSWERS="1
51820
1.1.1.1
1
y
y
203.0.113.10"

@test "prompt text for every required wizard prompt is actually visible" {
	run_pty "$FULL_ANSWERS"
	[ "$status" -eq 0 ]
	for needle in \
		"Select [1-6, default 1]:" \
		"WireGuard UDP port [51820]:" \
		"Client DNS" \
		"Select [1-2, default 1]:" \
		"Enable per-client preshared keys" \
		"Isolate clients from each other" \
		"Detected public endpoint"
	do
		[[ "$output" == *"$needle"* ]] || {
			echo "missing prompt text: $needle" >&2
			echo "--- captured output ---" >&2
			echo "$output" >&2
			return 1
		}
	done
}

@test "those exact prompt strings have not drifted from install.sh's wizard" {
	# The probe's copies are literal strings, independent of install.sh's
	# source, so a future edit to install.sh's wording could silently stop
	# being covered by the test above. Guard against that by asserting the
	# same literal substrings still exist in install.sh itself (fixed-string
	# match throughout - these are literal brackets/parens, not regex).
	for needle in \
		"Select [1-6, default 1]: " \
		'WireGuard UDP port [${OPT_PORT}]: ' \
		"Client DNS (comma-separated, blank for none)" \
		"Select [1-2, default 1]: " \
		"Enable per-client preshared keys (recommended)?" \
		"Isolate clients from each other (block peer-to-peer traffic)?" \
		"Detected public endpoint"
	do
		grep -Fq -- "$needle" "$INSTALL_SH"
	done
}

index_of() {
	# Byte offset of the first occurrence of a literal needle in $output,
	# via grep -b (fixed-string); empty/absent prints nothing and fails.
	grep -abo -F -- "$1" <<<"$output" | head -n1 | cut -d: -f1
}

@test "prompts appear in order, each before its own answer, with no duplicates" {
	run_pty "$FULL_ANSWERS"
	[ "$status" -eq 0 ]
	local pos_mode pos_port pos_dns pos_fwd pos_endpoint
	pos_mode="$(index_of 'Select [1-6, default 1]:')"
	pos_port="$(index_of 'WireGuard UDP port')"
	pos_dns="$(index_of 'Client DNS')"
	pos_fwd="$(index_of 'Select [1-2, default 1]:')"
	pos_endpoint="$(index_of 'Detected public endpoint')"
	[ -n "$pos_mode" ] && [ -n "$pos_port" ] && [ -n "$pos_dns" ] && [ -n "$pos_fwd" ] && [ -n "$pos_endpoint" ]
	[ "$pos_mode" -lt "$pos_port" ]
	[ "$pos_port" -lt "$pos_dns" ]
	[ "$pos_dns" -lt "$pos_fwd" ]
	[ "$pos_fwd" -lt "$pos_endpoint" ]

	# No prompt is printed twice (a regression here would mean the wizard
	# is re-asking, or printing the prompt once to the wrong stream and
	# once to the right one).
	local count
	count="$(grep -o -F 'Select [1-6, default 1]:' <<<"$output" | wc -l)"
	[ "$count" -eq 1 ]
}

@test "a warn() emitted after several prompts is still visible (stderr not clobbered)" {
	run_pty "$FULL_ANSWERS"
	[ "$status" -eq 0 ]
	[[ "$output" == *"probe warning after prompts"* ]]
}

@test "blank answers (pressing Enter) keep the documented defaults" {
	run_pty "

1.1.1.1

n
n
"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_MODE=full4"* ]]
	[[ "$output" == *"GOT_PORT=51820"* ]]
	[[ "$output" == *"GOT_FORWARD=nat"* ]]
	[[ "$output" == *"GOT_ENDPOINT=203.0.113.10"* ]]
}

@test "confirm() yes/no hint brackets are correct and the answer is honored" {
	run_pty "$FULL_ANSWERS"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Enable per-client preshared keys (recommended)? [Y/n]:"* ]]
	[[ "$output" == *"Isolate clients from each other (block peer-to-peer traffic)? [Y/n]:"* ]]
	[[ "$output" == *"GOT_PSK=yes"* ]]
	[[ "$output" == *"GOT_ISOLATION=yes"* ]]

	run_pty "1
51820
1.1.1.1
1
n
n
203.0.113.10"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT_PSK=no"* ]]
	[[ "$output" == *"GOT_ISOLATION=no"* ]]
}

@test "installer source over stdin is never consumed as a prompt answer" {
	run_pty "$FULL_ANSWERS"
	[ "$status" -eq 0 ]
	[[ "$output" != *"comment-line-after"* ]]
	[[ "$output" == *"GOT_PORT=51820"* ]]
}

@test "with no controlling terminal at all, the probe fails fast instead of hanging" {
	run python3 "$HARNESS" --script "$PROBE" --no-tty --timeout 10
	[ "$status" -ne 0 ]
	[ "$status" -ne 124 ]  # must not be our own timeout/hang sentinel
	[[ "$output" == *"no controlling terminal is available"* ]]
}

@test "direct execution (stdin already a real terminal) still works" {
	# When stdin itself is the real terminal (WGVPN_TTY_FD=0 path), the
	# harness's own pipe-based stdin doesn't apply - exercise this by
	# running the probe with its stdin attached directly to the pty
	# (no separate script-over-pipe layer), matching `bash install.sh`
	# executed normally rather than through a pipe.
	run python3 "$HARNESS" --script "$PROBE" --answers-file <(printf '%s\n' "$FULL_ANSWERS") --direct-stdin --timeout 20
	[ "$status" -eq 0 ]
	[[ "$output" == *"Select [1-6, default 1]:"* ]]
	[[ "$output" == *"GOT_PORT=51820"* ]]
}

@test "non-interactive install.sh parsing is unaffected (no prompt_read reached)" {
	run bash "${INSTALL_SH}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--non-interactive"* ]]
}
