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

# diag_human_bytes <n>: formats a byte count the way `wg show` does.
diag_human_bytes() {
	local n="${1:-0}"
	[[ "$n" =~ ^[0-9]+$ ]] || n=0
	if [ "$n" -ge 1073741824 ]; then
		awk -v n="$n" 'BEGIN { printf "%.2f GiB", n/1073741824 }'
	elif [ "$n" -ge 1048576 ]; then
		awk -v n="$n" 'BEGIN { printf "%.2f MiB", n/1048576 }'
	elif [ "$n" -ge 1024 ]; then
		awk -v n="$n" 'BEGIN { printf "%.2f KiB", n/1024 }'
	else
		echo "${n} B"
	fi
}

# diag_client_report <name>: a human-readable, secret-free connectivity
# report for one client - configured/enabled/loaded-live state, latest
# handshake, transfer counters, and a plain-language interpretation.
# Never fails just because a newly-created client has never handshaken
# yet; that is reported as a normal (if unhelpful-until-it-connects) state,
# not an error. Used by both `diagnostics_run` (for every client) and
# `wg-vpn test-client <name>` (for one).
diag_client_report() {
	local name="$1" f
	f="$(peer_file "$name")"
	if [ ! -f "$f" ]; then
		echo "Client ${name}: not configured."
		return 1
	fi

	local enabled pubkey created
	enabled="$(json_get "$f" enabled)"
	pubkey="$(json_get "$f" public_key)"
	created="$(json_get "$f" created)"

	local live="no" hs_epoch=0 rx=0 tx=0
	if wg_iface_up && [ -n "$pubkey" ]; then
		local line
		line="$(wg show "$WGVPN_IFACE" dump 2>/dev/null | awk -v pk="$pubkey" '$1==pk')"
		if [ -n "$line" ]; then
			live="yes"
			hs_epoch="$(awk '{print $5}' <<<"$line")"
			rx="$(awk '{print $6}' <<<"$line")"
			tx="$(awk '{print $7}' <<<"$line")"
		fi
	fi
	[[ "$hs_epoch" =~ ^[0-9]+$ ]] || hs_epoch=0

	local hs_human="never"
	if [ "$hs_epoch" -gt 0 ]; then
		hs_human="$(date -d "@${hs_epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "epoch ${hs_epoch}")"
	fi

	local interp
	if [ "$enabled" != "true" ]; then
		interp="client is disabled; it will not be able to connect until re-enabled ('wg-vpn enable-client ${name}')."
	elif [ "$live" != "yes" ]; then
		interp="this client is not loaded on the live WireGuard interface, so it cannot possibly connect regardless of network/firewall setup. Run 'sudo wg-vpn repair' to re-sync the live interface from the saved configuration."
	elif [ "$hs_epoch" -eq 0 ]; then
		local created_epoch now age
		created_epoch="$(date -d "$created" '+%s' 2>/dev/null || echo 0)"
		now="$(date '+%s')"
		age=$(( now - created_epoch ))
		if [ "$created_epoch" -gt 0 ] && [ "$age" -lt 120 ]; then
			interp="server has never received an authenticated packet from this client yet, but it was only just created (${age}s ago) - this is normal until the client device imports the config and connects."
		else
			interp="server has never received an authenticated packet from this client. Check: the client's Endpoint is this server's real, internet-reachable address/port; the UDP port is open in this server's firewall AND any VPS-provider/cloud security-group firewall outside this OS (software here cannot see or fix that layer); and the client device itself has a working internet connection."
		fi
	else
		local now age
		now="$(date '+%s')"
		age=$(( now - hs_epoch ))
		if [ "$age" -le 300 ]; then
			interp="recent handshake (${age}s ago); the tunnel appears healthy at the WireGuard layer. If the client still can't reach the internet/DNS, check IP forwarding, NAT, and firewall FORWARD rules on the server instead."
		else
			interp="last handshake was ${age}s ago, which is stale for a client with keepalive enabled; it may be offline, asleep, or its network may have changed/dropped."
		fi
	fi

	echo "Client ${name}:"
	echo "  Configured: yes"
	echo "  Enabled: $([ "$enabled" = "true" ] && echo yes || echo no)"
	echo "  Loaded live: ${live}"
	echo "  Latest handshake: ${hs_human}"
	echo "  RX: $(diag_human_bytes "$rx")"
	echo "  TX: $(diag_human_bytes "$tx")"
	echo "  Interpretation: ${interp}"
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

	# The live interface existing is what actually matters; the systemd
	# unit being "active" is how that normally happens on a real VPS, but
	# treating "no systemd" as a hard FAIL here would be wrong in any
	# container/CI/non-systemd environment where the interface was
	# brought up another way (eg. 'wg-quick up' directly) and is working
	# fine. wg_apply_peer_live()/wg_service_restart() have the same
	# wg_iface_up-based logic for the same reason.
	local svc_state
	svc_state="$(wg_service_status 2>/dev/null)"
	if wg_iface_up; then
		if [ "$svc_state" = "active" ] || ! wg_systemd_available; then
			diag_report PASS "WireGuard interface ${WGVPN_IFACE} is up (wg-quick@${WGVPN_IFACE} service state: ${svc_state})"
		else
			diag_report WARN "WireGuard interface ${WGVPN_IFACE} is up, but its systemd unit reports '${svc_state}' - it may not survive a reboot. Run 'systemctl enable --now wg-quick@${WGVPN_IFACE}'."
		fi
	else
		diag_report FAIL "WireGuard interface ${WGVPN_IFACE} is not up (wg-quick@${WGVPN_IFACE} service state: ${svc_state})"
	fi

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

	local iface configured_iface
	iface="$(net_default_iface)"
	[ -n "$iface" ] && diag_report PASS "Default public interface: ${iface}" || diag_report WARN "Could not determine default public interface"
	configured_iface="$(json_get "$WGVPN_CONF" public_iface 2>/dev/null)"
	if [ -n "$configured_iface" ] && [ -n "$iface" ] && [ "$configured_iface" != "$iface" ]; then
		diag_report WARN "Configured public interface (${configured_iface}) differs from the current default-route interface (${iface}) - NAT/masquerade is applied to ${configured_iface} and may no longer be the real egress path. Run 'sudo wg-vpn repair' if this host's networking changed."
	fi

	local endpoint endpoint_host
	endpoint="$(json_get "$WGVPN_CONF" endpoint 2>/dev/null)"
	if [ -n "$endpoint" ]; then
		diag_report PASS "Endpoint configured: ${endpoint}"
		endpoint_host="${endpoint%:*}"
		endpoint_host="${endpoint_host#\[}"; endpoint_host="${endpoint_host%\]}"
		if valid_ipv4 "$endpoint_host"; then
			if ipv4_is_global_unicast "$endpoint_host"; then
				diag_report PASS "Endpoint address is a publicly-routable IPv4 address"
			else
				diag_report FAIL "Endpoint address (${endpoint_host}) is a private/reserved IPv4 address - clients on the public internet cannot reach this server here. Re-run 'sudo wg-vpn repair' after fixing the endpoint, or edit it via the installer's --endpoint flag."
			fi
		elif valid_ipv6 "$endpoint_host"; then
			ipv6_is_global_unicast "$endpoint_host" \
				&& diag_report PASS "Endpoint address is a global IPv6 address" \
				|| diag_report FAIL "Endpoint address (${endpoint_host}) is a link-local/ULA IPv6 address - not reachable from the public internet."
		else
			if command_exists getent && getent ahostsv4 "$endpoint_host" >/dev/null 2>&1; then
				diag_report PASS "Endpoint hostname (${endpoint_host}) resolves"
			elif command_exists getent && getent ahosts "$endpoint_host" >/dev/null 2>&1; then
				diag_report PASS "Endpoint hostname (${endpoint_host}) resolves"
			else
				diag_report WARN "Endpoint hostname (${endpoint_host}) does not currently resolve from this server (DNS issue, or it genuinely doesn't exist)."
			fi
		fi
	else
		diag_report WARN "No endpoint configured"
	fi

	local fwreport backend
	fwreport="$(fw_status_report 2>/dev/null)"
	backend="$(awk -F= '/^backend=/{print $2}' <<<"$fwreport")"
	[ "$backend" != "none" ] && [ -n "$backend" ] && diag_report PASS "Firewall backend: ${backend}" || diag_report FAIL "No firewall backend available"
	if [[ "$fwreport" == *"port_rule=present"* ]]; then
		diag_report PASS "Project firewall rule for WireGuard port present"
	else
		diag_report WARN "Project firewall rule for WireGuard port not found"
	fi
	if [[ "$fwreport" == *"nat_rule=present"* ]]; then
		diag_report PASS "Project NAT/masquerade rule present"
	elif [ "$(json_get "$WGVPN_CONF" forward_mode 2>/dev/null)" = "nat" ]; then
		diag_report FAIL "forward_mode is 'nat' but no masquerade rule was found - clients will not reach the internet through this server."
	fi
	if [[ "$fwreport" == *"forward_rule=present"* ]]; then
		diag_report PASS "Project nftables forwarding chain for ${WGVPN_IFACE} exists"
	else
		diag_report WARN "No project nftables forwarding chain found for ${WGVPN_IFACE}."
	fi

	# The project's own forwarding chain existing does NOT guarantee traffic
	# is ultimately accepted: nftables evaluates every base chain hooked to
	# "forward" independently, in priority order, so a host-level chain
	# with its own DROP policy (eg. Docker's, or an administrator's) can
	# still drop the same packets after the project's chain already
	# accepted them. Check the actual effective path instead.
	local host_policy compat_status
	host_policy="$(awk -F= '/^host_forward_policy=/{print $2}' <<<"$fwreport")"
	compat_status="$(awk -F= '/^compat_forward_rule=/{print $2}' <<<"$fwreport")"
	case "$host_policy" in
		ACCEPT)
			diag_report PASS "WireGuard traffic is permitted through host FORWARD chain (policy ACCEPT)"
			;;
		DROP|REJECT)
			if [ "$compat_status" = "present" ]; then
				diag_report PASS "WireGuard traffic is permitted through host FORWARD chain (policy ${host_policy}, project compatibility rules present)"
			else
				diag_report WARN "Host FORWARD policy is ${host_policy} and required WireGuard compatibility rules are missing - clients may handshake but be unable to reach the internet. Run 'sudo wg-vpn repair' to install them."
			fi
			;;
		*)
			diag_report WARN "Could not determine the host's effective FORWARD policy (iptables unavailable?) - if clients handshake but cannot reach the internet, check 'iptables -L FORWARD -v' or 'nft list ruleset' manually for a conflicting DROP policy (eg. from Docker)."
			;;
	esac

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

		if [ "$count" -gt 0 ]; then
			echo "------------------------------------"
			local f name stale_never_handshake=0
			for f in "$WGVPN_CLIENTS_DIR"/*.json; do
				[ -e "$f" ] || continue
				name="$(json_get "$f" name)"
				diag_client_report "$name"
				# Evidence-based, not assumed: only counts a client whose
				# handshake has genuinely never happened despite being
				# enabled, live, and old enough that a normal client would
				# have connected by now - never a just-created one.
				if [ "$(json_get "$f" enabled)" = "true" ] && wg_iface_up; then
					local pk hs created_epoch now
					pk="$(json_get "$f" public_key)"
					hs="$(wg show "$WGVPN_IFACE" dump 2>/dev/null | awk -v pk="$pk" '$1==pk{print $5}')"
					[[ "$hs" =~ ^[0-9]+$ ]] || hs=0
					created_epoch="$(date -d "$(json_get "$f" created)" '+%s' 2>/dev/null || echo 0)"
					now="$(date '+%s')"
					if [ "$hs" -eq 0 ] && [ "$created_epoch" -gt 0 ] && [ $(( now - created_epoch )) -ge 120 ]; then
						stale_never_handshake=1
					fi
				fi
			done
			echo "------------------------------------"
			if [ "$stale_never_handshake" = "1" ]; then
				diag_report WARN "At least one enabled client has never handshaken despite being configured for a while. Since every OS-level check above passed, the most likely remaining cause is a firewall OUTSIDE this server - a VPS provider's security group or cloud firewall blocking inbound UDP ${port:-the WireGuard port} - which this software cannot see or change; check your hosting provider's firewall settings."
			fi
		fi
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
