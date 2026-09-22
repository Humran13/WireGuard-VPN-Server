#!/usr/bin/env bash
# diagnostics.sh - PASS/WARN/FAIL health checks (never prints private keys)
# shellcheck shell=bash

if [ -n "${WGVPN_DIAG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_DIAG_LOADED=1

WGVPN_DIAG_FAILS=0
WGVPN_DIAG_WARNS=0

diag_report() {
	local status="$1" msg="$2"
	case "$status" in
		PASS) printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$msg" ;;
		WARN) printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$msg"; WGVPN_DIAG_WARNS=$((WGVPN_DIAG_WARNS+1)) ;;
		FAIL) printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$msg"; WGVPN_DIAG_FAILS=$((WGVPN_DIAG_FAILS+1)) ;;
	esac
}

diagnostics_run() {
	WGVPN_DIAG_FAILS=0; WGVPN_DIAG_WARNS=0
	echo "WireGuard VPN Server - Diagnostics"
	echo "===================================="

	[ "$(id -u)" -eq 0 ] && diag_report PASS "Running as root" || diag_report FAIL "Not running as root"

	if os_read_release; then
		if os_is_tested "$OS_VERSION_ID"; then
			diag_report PASS "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) - tested release"
		else
			diag_report WARN "Ubuntu ${OS_VERSION_ID} - untested release, compatibility mode"
		fi
	else
		diag_report FAIL "Could not detect /etc/os-release"
	fi

	diag_report PASS "Kernel: $(uname -r)"

	local wgmod
	wgmod="$(os_kernel_wireguard_status)"
	case "$wgmod" in
		builtin) diag_report PASS "WireGuard kernel support: built-in" ;;
		module) diag_report PASS "WireGuard kernel support: module loaded" ;;
		*) diag_report FAIL "WireGuard kernel module not detected" ;;
	esac

	command_exists wg && diag_report PASS "wg tool present ($(wg --version 2>/dev/null | head -n1))" || diag_report FAIL "wg tool missing"
	command_exists wg-quick && diag_report PASS "wg-quick present" || diag_report FAIL "wg-quick missing"

	if [ -f "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf" ]; then
		if wg_config_syntax_ok; then
			diag_report PASS "WireGuard configuration parses correctly"
		else
			diag_report FAIL "WireGuard configuration failed to parse (wg-quick strip)"
		fi
	else
		diag_report FAIL "No configuration found at ${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
	fi

	local svc_state
	svc_state="$(wg_service_status 2>/dev/null)"
	[ "$svc_state" = "active" ] && diag_report PASS "wg-quick@${WGVPN_IFACE} service is active" || diag_report FAIL "wg-quick@${WGVPN_IFACE} service is not active (state: ${svc_state})"

	local port
	port="$(json_get "$WGVPN_CONF" wg_port 2>/dev/null)"
	if [ -n "$port" ]; then
		if command_exists ss && ss -uln 2>/dev/null | grep -q ":${port}\b"; then
			diag_report PASS "UDP port ${port} is listening"
		else
			diag_report WARN "Could not confirm UDP port ${port} is listening"
		fi
	fi

	local fwd
	fwd="$(net_sysctl_forwarding_status)"
	[[ "$fwd" == *"ipv4=1"* ]] && diag_report PASS "IPv4 forwarding enabled" || diag_report FAIL "IPv4 forwarding disabled"
	local v6_enabled
	v6_enabled="$(json_get "$WGVPN_CONF" ipv6_enabled 2>/dev/null)"
	if [ "$v6_enabled" = "true" ]; then
		[[ "$fwd" == *"ipv6=1"* ]] && diag_report PASS "IPv6 forwarding enabled" || diag_report FAIL "IPv6 forwarding disabled but IPv6 mode is configured"
	fi

	local iface
	iface="$(net_default_iface)"
	[ -n "$iface" ] && diag_report PASS "Default public interface: ${iface}" || diag_report WARN "Could not determine default public interface"

	local endpoint
	endpoint="$(json_get "$WGVPN_CONF" endpoint 2>/dev/null)"
	[ -n "$endpoint" ] && diag_report PASS "Endpoint configured: ${endpoint}" || diag_report WARN "No endpoint configured"

	local fwreport backend
	fwreport="$(fw_status_report 2>/dev/null)"
	backend="$(awk -F= '/^backend=/{print $2}' <<<"$fwreport")"
	[ "$backend" != "none" ] && [ -n "$backend" ] && diag_report PASS "Firewall backend: ${backend}" || diag_report FAIL "No firewall backend available"
	if [[ "$fwreport" == *"port_rule=present"* ]]; then
		diag_report PASS "Project firewall rule for WireGuard port present"
	else
		diag_report WARN "Project firewall rule for WireGuard port not found"
	fi

	command_exists qrencode && diag_report PASS "qrencode available for QR codes" || diag_report WARN "qrencode not installed (QR export unavailable)"

	if [ -d "$WGVPN_CLIENTS_DIR" ]; then
		local dupe
		dupe="$(diag_duplicate_addresses)"
		if [ -n "$dupe" ]; then
			diag_report FAIL "Duplicate client VPN addresses detected: ${dupe}"
		else
			diag_report PASS "No duplicate client VPN addresses"
		fi
		local count
		count="$(find "$WGVPN_CLIENTS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
		diag_report PASS "Configured clients: ${count}"
	fi

	if [ -d "$WGVPN_WG_DIR" ]; then
		local perm
		perm="$(stat -c '%a' "$WGVPN_WG_DIR" 2>/dev/null)"
		if [ "$perm" = "700" ] || [ "$perm" = "600" ]; then
			diag_report PASS "${WGVPN_WG_DIR} permissions are restricted (${perm})"
		else
			diag_report WARN "${WGVPN_WG_DIR} permissions are ${perm:-unknown}, expected 700"
		fi
	fi

	if command_exists journalctl; then
		local errs
		errs="$(journalctl -u "wg-quick@${WGVPN_IFACE}" --since "1 hour ago" -p err 2>/dev/null | wc -l)"
		[ "$errs" -eq 0 ] && diag_report PASS "No recent systemd errors for wg-quick@${WGVPN_IFACE}" || diag_report WARN "${errs} recent error log lines for wg-quick@${WGVPN_IFACE}"
	fi

	echo "===================================="
	echo "Summary: ${WGVPN_DIAG_FAILS} FAIL, ${WGVPN_DIAG_WARNS} WARN"
	[ "$WGVPN_DIAG_FAILS" -eq 0 ]
}

diag_duplicate_addresses() {
	local f addr seen=()
	[ -d "$WGVPN_CLIENTS_DIR" ] || return 0
	for f in "$WGVPN_CLIENTS_DIR"/*.json; do
		[ -e "$f" ] || continue
		addr="$(json_get "$f" vpn_ipv4)"
		if [ -z "$addr" ]; then continue; fi
		if printf '%s\n' "${seen[@]:-}" | grep -qx "$addr"; then
			echo "$addr"
		fi
		seen+=("$addr")
	done
}
