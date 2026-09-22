#!/usr/bin/env bash
# os.sh - OS detection and Ubuntu release support matrix
# shellcheck shell=bash

if [ -n "${WGVPN_OS_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_OS_LOADED=1

# Explicitly tested Ubuntu major.minor releases.
WGVPN_TESTED_RELEASES=("18.04" "20.04" "22.04" "24.04" "26.04")

# os_read_release [/etc/os-release path]
# Sets globals: OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY_NAME
os_read_release() {
	local file="${1:-/etc/os-release}"
	OS_ID=""; OS_VERSION_ID=""; OS_CODENAME=""; OS_PRETTY_NAME=""
	if [ ! -f "$file" ]; then
		return 1
	fi
	# shellcheck disable=SC1090
	local id version_id codename pretty
	id="$(sed -n 's/^ID=//p' "$file" | tr -d '"' | head -n1)"
	version_id="$(sed -n 's/^VERSION_ID=//p' "$file" | tr -d '"' | head -n1)"
	codename="$(sed -n 's/^VERSION_CODENAME=//p' "$file" | tr -d '"' | head -n1)"
	pretty="$(sed -n 's/^PRETTY_NAME=//p' "$file" | tr -d '"' | head -n1)"
	OS_ID="$id"
	OS_VERSION_ID="$version_id"
	OS_CODENAME="$codename"
	OS_PRETTY_NAME="$pretty"
	[ -n "$OS_ID" ]
}

# os_version_is_ubuntu_ge <version_id> <min_major.minor>
# Numeric comparison of "YY.MM" style versions.
os_version_ge() {
	local a="$1" b="$2"
	local a_major=${a%%.*} a_minor=${a#*.}
	local b_major=${b%%.*} b_minor=${b#*.}
	a_minor=${a_minor%%.*}; b_minor=${b_minor%%.*}
	# strip leading zeros to avoid octal issues
	a_major=$((10#$a_major)); a_minor=$((10#$a_minor))
	b_major=$((10#$b_major)); b_minor=$((10#$b_minor))
	if [ "$a_major" -gt "$b_major" ]; then return 0; fi
	if [ "$a_major" -lt "$b_major" ]; then return 1; fi
	[ "$a_minor" -ge "$b_minor" ]
}

os_is_tested() {
	local v="$1" r
	for r in "${WGVPN_TESTED_RELEASES[@]}"; do
		if [ "$v" = "$r" ]; then return 0; fi
	done
	return 1
}

# os_check_support: verifies OS is Ubuntu >= 18.04, prints compatibility notice.
# Sets OS_SUPPORT_MODE to "tested" or "compat".
os_check_support() {
	if ! os_read_release; then
		die "Cannot detect OS: /etc/os-release not found. This installer supports Ubuntu only."
	fi
	if [ "$OS_ID" != "ubuntu" ]; then
		die "Unsupported OS '${OS_ID:-unknown}'. This installer supports Ubuntu 18.04+ only."
	fi
	if [ -z "$OS_VERSION_ID" ]; then
		die "Could not determine Ubuntu VERSION_ID."
	fi
	if ! os_version_ge "$OS_VERSION_ID" "18.04"; then
		die "Ubuntu ${OS_VERSION_ID} is too old. Minimum supported release is 18.04."
	fi
	if os_is_tested "$OS_VERSION_ID"; then
		OS_SUPPORT_MODE="tested"
		info "Detected Ubuntu ${OS_VERSION_ID} (${OS_CODENAME:-unknown}) - explicitly tested release."
	else
		OS_SUPPORT_MODE="compat"
		warn "This Ubuntu release has not been explicitly tested. Continuing with compatibility mode."
		info "Detected Ubuntu ${OS_VERSION_ID} (${OS_CODENAME:-unknown})."
	fi
}

# os_arch: normalized CPU architecture
os_arch() {
	local m
	m="$(uname -m)"
	case "$m" in
		x86_64|amd64) echo "amd64" ;;
		aarch64|arm64) echo "arm64" ;;
		armv7l|armhf) echo "armhf" ;;
		*) echo "$m" ;;
	esac
}

# os_kernel_wireguard_status: prints "module"|"builtin"|"missing"
os_kernel_wireguard_status() {
	if [ -d /sys/module/wireguard ]; then
		echo "builtin"
		return 0
	fi
	if command_exists modinfo && modinfo wireguard >/dev/null 2>&1; then
		echo "module"
		return 0
	fi
	if lsmod 2>/dev/null | grep -q '^wireguard'; then
		echo "module"
		return 0
	fi
	echo "missing"
}

# os_install_packages <pkg...>  - apt-get wrapper, non-interactive
os_install_packages() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq || warn "apt-get update reported errors; continuing"
	apt-get install -y -qq "$@"
}
