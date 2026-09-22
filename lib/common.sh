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

# --- Temp files / atomic writes --------------------------------------------
WGVPN_TMPFILES=()
wgvpn_cleanup_tmp() {
	local f
	for f in "${WGVPN_TMPFILES[@]:-}"; do
		if [ -n "$f" ] && [ -e "$f" ]; then rm -f -- "$f"; fi
	done
}
trap wgvpn_cleanup_tmp EXIT

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
	if [ ! -t 0 ]; then
		[ "$default" = "y" ] && return 0 || return 1
	fi
	read -r -p "$prompt [$hint]: " reply || true
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
