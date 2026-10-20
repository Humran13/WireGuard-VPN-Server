#!/usr/bin/env bash
# common.sh - shared helpers: logging, error handling, paths, version, safe I/O
# shellcheck shell=bash

if [ -n "${WGVPN_COMMON_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_COMMON_LOADED=1

# --- Paths (single source of truth) ---------------------------------------
WGVPN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
WGVPN_PREFIX="${WGVPN_PREFIX:-/opt/wireguard-vpn-server}"
WGVPN_STATE_DIR="${WGVPN_STATE_DIR:-/etc/wireguard-vpn-server}"
WGVPN_WG_DIR="${WGVPN_WG_DIR:-/etc/wireguard}"
WGVPN_BIN="${WGVPN_BIN:-/usr/local/bin/wg-vpn}"
WGVPN_IFACE="${WGVPN_IFACE:-wg0}"
WGVPN_CONF="${WGVPN_STATE_DIR}/config.json"
WGVPN_CLIENTS_DIR="${WGVPN_STATE_DIR}/clients"
WGVPN_PEERS_DIR="${WGVPN_STATE_DIR}/site-peers"
WGVPN_BACKUP_DIR="${WGVPN_STATE_DIR}/backups"
WGVPN_LOG_FILE="${WGVPN_STATE_DIR}/install.log"
WGVPN_FW_STATE="${WGVPN_STATE_DIR}/firewall.state"
WGVPN_SYSCTL_FILE="/etc/sysctl.d/99-wireguard-vpn-server.conf"

# --- Version ---------------------------------------------------------------
wgvpn_version() {
	local f
	for f in "${WGVPN_LIB_DIR}/../VERSION" "${WGVPN_PREFIX}/VERSION"; do
		if [ -f "$f" ]; then
			tr -d ' \t\n\r' <"$f"
			return 0
		fi
	done
	echo "unknown"
}
WGVPN_VERSION="$(wgvpn_version)"

# --- Colors / logging --------------------------------------------------------
if [ -t 1 ] && [ "${WGVPN_NO_COLOR:-0}" != "1" ]; then
	C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
	C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
	C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

wgvpn_log() {
	local level="$1"; shift
	local msg="$*"
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	if [ -w "$(dirname "$WGVPN_LOG_FILE")" ] 2>/dev/null || [ -w "$WGVPN_LOG_FILE" ] 2>/dev/null; then
		printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$WGVPN_LOG_FILE" 2>/dev/null || true
	fi
}

info()  { printf '%s[INFO]%s  %s\n'  "$C_BLUE"  "$C_RESET" "$*"; wgvpn_log INFO "$*"; }
ok()    { printf '%s[ OK ]%s  %s\n'  "$C_GREEN" "$C_RESET" "$*"; wgvpn_log OK "$*"; }
warn()  { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; wgvpn_log WARN "$*"; }
err()   { printf '%s[FAIL]%s  %s\n'  "$C_RED"   "$C_RESET" "$*" >&2; wgvpn_log FAIL "$*"; }
die()   { err "$*"; exit 1; }

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "This command must be run as root (try: sudo $0 $*)"
	fi
}

# --- Coordinated EXIT handling ----------------------------------------------
# A plain `trap foo EXIT` silently replaces any trap set earlier in the
# process (eg. by install.sh's own bootstrap code), so cleanup handlers can
# go missing without any error. wgvpn_on_exit lets any number of callers
# register a handler; they all run, in reverse-registration (LIFO) order,
# when the process exits. install.sh defines a copy of this same mechanism
# before common.sh is even sourced (it needs it earlier, to register
# cleanup for its fetched-sources bootstrap) - the guard below means
# whichever copy runs first wins and the other is a no-op.
if ! declare -f wgvpn_on_exit >/dev/null 2>&1; then
	WGVPN_EXIT_HOOKS=()
	wgvpn_on_exit() { WGVPN_EXIT_HOOKS+=("$1"); }
	# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT`
	wgvpn_run_exit_hooks() {
		local ec=$? i hook
		for (( i=${#WGVPN_EXIT_HOOKS[@]}-1; i>=0; i-- )); do
			hook="${WGVPN_EXIT_HOOKS[i]}"
			[ -n "$hook" ] && "$hook" "$ec"
		done
	}
	trap wgvpn_run_exit_hooks EXIT
fi

# --- Controlling-terminal input (safe for `curl | bash`) --------------------
# When this script's own stdin is a pipe (eg. `curl ... | bash`), reading
# with `read -p` consumes the remaining installer source as if it were
# typed answers instead of waiting for the user. WGVPN_TTY_FD routes
# interactive reads to the controlling terminal in that case, while still
# honoring a real redirected/piped stdin for non-interactive automation
# (eg. `./install.sh < answers.txt`).
WGVPN_TTY_FD=""
WGVPN_TTY_CHECKED=0
wgvpn_init_tty() {
	[ "$WGVPN_TTY_CHECKED" = "1" ] && return 0
	WGVPN_TTY_CHECKED=1
	if [ -t 0 ]; then
		WGVPN_TTY_FD=0
	elif exec 3<>/dev/tty 2>/dev/null; then
		WGVPN_TTY_FD=3
		wgvpn_on_exit wgvpn_close_tty
	fi
}
# shellcheck disable=SC2329  # invoked indirectly via wgvpn_on_exit
wgvpn_close_tty() {
	if [ "$WGVPN_TTY_FD" = "3" ]; then exec 3<&- 2>/dev/null || true; fi
}

# prompt_read <var> <prompt-text>
# Equivalent to `read -r -p "<prompt-text>" <var>`, except the answer is
# always read from the controlling terminal rather than this script's own
# stdin (unless stdin is itself a real terminal). Dies with a clear error
# if interactive input was requested but no terminal is reachable, rather
# than silently reading installer source or hanging forever.
prompt_read() {
	local __var="$1" __prompt="$2" __reply="" __status=0
	wgvpn_init_tty
	if [ -z "$WGVPN_TTY_FD" ]; then
		die "Interactive input requested but no controlling terminal is available (stdin is not a tty and /dev/tty could not be opened). Re-run with --non-interactive, or pass the relevant --flag."
	fi
	read -r -p "$__prompt" __reply <&"$WGVPN_TTY_FD" || __status=$?
	printf -v "$__var" '%s' "$__reply"
	return "$__status"
}

# --- Temp files / atomic writes --------------------------------------------
WGVPN_TMPFILES=()
# shellcheck disable=SC2329  # invoked indirectly via wgvpn_on_exit
wgvpn_cleanup_tmp() {
	local f
	for f in "${WGVPN_TMPFILES[@]:-}"; do
		if [ -n "$f" ] && [ -e "$f" ]; then rm -f -- "$f"; fi
	done
}
wgvpn_on_exit wgvpn_cleanup_tmp

wgvpn_mktemp() {
	local dir="${1:-${TMPDIR:-/tmp}}"
	local t
	t="$(mktemp "${dir}/wgvpn.XXXXXXXX")" || die "mktemp failed"
	WGVPN_TMPFILES+=("$t")
	printf '%s\n' "$t"
}

# atomic_write <dest> <mode>  -- writes stdin to dest atomically
atomic_write() {
	local dest="$1" mode="${2:-0600}"
	local dir tmp
	dir="$(dirname -- "$dest")"
	[ -d "$dir" ] || mkdir -p -- "$dir"
	tmp="$(mktemp "${dir}/.wgvpn.XXXXXXXX")" || die "mktemp failed for $dest"
	cat >"$tmp"
	chmod "$mode" "$tmp"
	mv -f -- "$tmp" "$dest"
}

confirm() {
	local prompt="${1:-Are you sure?}" default="${2:-n}"
	local reply hint
	[ "$default" = "y" ] && hint="Y/n" || hint="y/N"
	if [ "${WGVPN_ASSUME_YES:-0}" = "1" ]; then return 0; fi
	# Deliberately check WGVPN_TTY_FD directly (not prompt_read, which dies
	# when no terminal is reachable): confirm() must fall back to the
	# default instead of aborting, so true non-interactive runs never hang
	# or fail just because they hit a confirmation.
	wgvpn_init_tty
	if [ -z "$WGVPN_TTY_FD" ]; then
		[ "$default" = "y" ] && return 0 || return 1
	fi
	read -r -p "$prompt [$hint]: " reply <&"$WGVPN_TTY_FD" || true
	reply="${reply:-$default}"
	case "$reply" in
		[Yy]|[Yy][Ee][Ss]) return 0 ;;
		*) return 1 ;;
	esac
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# --- Minimal JSON helpers (require jq; installed by the installer) ---------
json_get() {
	local file="$1" key="$2"
	jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
}

# json_set <file> <key> <value> [type: string|raw]  - atomic in-place update
json_set() {
	local file="$1" key="$2" value="$3" type="${4:-string}"
	local tmp existing
	existing="$( [ -f "$file" ] && cat "$file" || echo '{}' )"
	if [ "$type" = "raw" ]; then
		tmp="$(printf '%s' "$existing" | jq --arg k "$key" --argjson v "$value" '.[$k]=$v')"
	else
		tmp="$(printf '%s' "$existing" | jq --arg k "$key" --arg v "$value" '.[$k]=$v')"
	fi
	printf '%s\n' "$tmp" | atomic_write "$file" 0600
}

umask 077
