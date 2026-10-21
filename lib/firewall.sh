#!/usr/bin/env bash
# firewall.sh - project-owned firewall rules (nftables preferred, iptables fallback, UFW-aware)
# shellcheck shell=bash

if [ -n "${WGVPN_FIREWALL_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_FIREWALL_LOADED=1

WGVPN_NFT_TABLE="wgvpnserver"
WGVPN_FW_COMMENT="wireguard-vpn-server"

fw_detect_backend() {
	if command_exists nft; then
		echo "nftables"
	elif command_exists iptables; then
		echo "iptables"
	else
		echo "none"
	fi
}

fw_ufw_active() {
	command_exists ufw || return 1
	ufw status 2>/dev/null | grep -qi "^Status: active"
}

# fw_apply <port> <forward_mode: nat|routed> <public_iface> <v4_subnet> [v6_subnet] [isolation: 1|0]
fw_apply() {
	local port="$1" mode="$2" pub_iface="$3" v4_subnet="$4" v6_subnet="${5:-}" isolation="${6:-1}"
	local backend
	backend="$(fw_detect_backend)"
	if [ "$backend" = "none" ]; then die "No supported firewall backend (nft or iptables) found."; fi

	mkdir -p "$(dirname "$WGVPN_FW_STATE")"

	# Read back any previously-recorded compat-rule interfaces BEFORE the
	# state file gets truncated below, so an interface change can be
	# reconciled (see fw_compat_forward_apply).
	local prev_compat_wg="" prev_compat_pub=""
	if [ -f "$WGVPN_FW_STATE" ]; then
		prev_compat_wg="$(sed -n 's/^compat_wg_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
		prev_compat_pub="$(sed -n 's/^compat_pub_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	fi

	if [ "$backend" = "nftables" ]; then
		echo "backend=nftables" >"$WGVPN_FW_STATE"
		fw_nft_apply "$port" "$mode" "$pub_iface" "$v4_subnet" "$v6_subnet" "$isolation"
	else
		echo "backend=iptables" >"$WGVPN_FW_STATE"
		fw_iptables_apply "$port" "$mode" "$pub_iface" "$v4_subnet" "$v6_subnet" "$isolation"
	fi

	# Independent of the backend chosen above for the project's own
	# dedicated tables: a project-owned nftables chain hooked to "forward"
	# does NOT guarantee WireGuard traffic is ultimately accepted. nftables
	# evaluates every base chain hooked to the same point independently, in
	# priority order - an `accept` verdict in one base chain only ends THAT
	# chain's processing and lets the packet continue to the next hooked
	# chain (eg. the standard `ip filter FORWARD` chain Docker/OpenVPN/ufw/
	# administrators populate via `iptables`), which can still drop it under
	# its own policy. Ensure narrow, project-owned ACCEPT rules exist at the
	# top of that chain too, whenever `iptables` is available.
	fw_compat_forward_apply "$WGVPN_IFACE" "$pub_iface" "$prev_compat_wg" "$prev_compat_pub"

	if fw_ufw_active; then
		info "UFW is active; adding an allow rule for the WireGuard port."
		ufw allow "${port}/udp" comment "$WGVPN_FW_COMMENT" >/dev/null 2>&1 || warn "Failed to add UFW rule; verify manually."
		echo "ufw=1" >>"$WGVPN_FW_STATE"
	fi
}

fw_nft_apply() {
	local port="$1" mode="$2" pub_iface="$3" v4_subnet="$4" v6_subnet="$5" isolation="${6:-1}"
	nft add table inet "$WGVPN_NFT_TABLE" 2>/dev/null || true
	nft "add chain inet ${WGVPN_NFT_TABLE} input { type filter hook input priority -1 ; policy accept ; }" 2>/dev/null || true
	nft flush chain inet "$WGVPN_NFT_TABLE" input 2>/dev/null || true
	nft add rule inet "$WGVPN_NFT_TABLE" input udp dport "$port" accept comment "\"$WGVPN_FW_COMMENT\""

	nft add table inet "${WGVPN_NFT_TABLE}_fwd" 2>/dev/null || true
	nft "add chain inet ${WGVPN_NFT_TABLE}_fwd forward { type filter hook forward priority -1 ; policy accept ; }" 2>/dev/null || true
	nft flush chain inet "${WGVPN_NFT_TABLE}_fwd" forward 2>/dev/null || true
	if [ "$isolation" = "1" ]; then
		nft add rule inet "${WGVPN_NFT_TABLE}_fwd" forward iifname "$WGVPN_IFACE" oifname "$WGVPN_IFACE" drop comment "\"$WGVPN_FW_COMMENT\""
	fi
	nft add rule inet "${WGVPN_NFT_TABLE}_fwd" forward iifname "$WGVPN_IFACE" accept comment "\"$WGVPN_FW_COMMENT\""
	nft add rule inet "${WGVPN_NFT_TABLE}_fwd" forward oifname "$WGVPN_IFACE" accept comment "\"$WGVPN_FW_COMMENT\""

	if [ "$mode" = "nat" ]; then
		nft add table ip "${WGVPN_NFT_TABLE}_nat" 2>/dev/null || true
		nft "add chain ip ${WGVPN_NFT_TABLE}_nat postrouting { type nat hook postrouting priority 100 ; }" 2>/dev/null || true
		nft flush chain ip "${WGVPN_NFT_TABLE}_nat" postrouting 2>/dev/null || true
		nft add rule ip "${WGVPN_NFT_TABLE}_nat" postrouting ip saddr "$v4_subnet" oifname "$pub_iface" masquerade comment "\"$WGVPN_FW_COMMENT\""

		if [ -n "$v6_subnet" ]; then
			nft add table ip6 "${WGVPN_NFT_TABLE}_nat6" 2>/dev/null || true
			nft "add chain ip6 ${WGVPN_NFT_TABLE}_nat6 postrouting { type nat hook postrouting priority 100 ; }" 2>/dev/null || true
			nft flush chain ip6 "${WGVPN_NFT_TABLE}_nat6" postrouting 2>/dev/null || true
			nft add rule ip6 "${WGVPN_NFT_TABLE}_nat6" postrouting ip6 saddr "$v6_subnet" oifname "$pub_iface" masquerade comment "\"$WGVPN_FW_COMMENT\""
		fi
	fi
}

# fw_compat_forward_apply <wg_iface> <pub_iface> [prev_wg_iface] [prev_pub_iface]
# Ensures two narrow, project-owned ACCEPT rules exist at the TOP of the
# host's real `iptables` FORWARD chain (position 1, so they are evaluated
# before any Docker DOCKER-USER/DOCKER-FORWARD jump and before the chain's
# own default policy applies): wg-iface -> pub-iface unconditionally, and
# pub-iface -> wg-iface for RELATED,ESTABLISHED traffic only. This is the
# chain Docker/OpenVPN/ufw/administrators actually populate; `iptables` on
# modern Ubuntu is iptables-nft, so this reaches the same underlying
# nftables `ip filter FORWARD` chain regardless of whether it was created
# by legacy iptables, iptables-nft, or raw nft rules.
# No-ops (with a warning) if `iptables` isn't installed at all - there is
# no reliable, universal way to locate an admin-defined custom nft chain
# in that case, and without iptables, Docker/OpenVPN (the common cause)
# cannot be present either.
fw_compat_forward_apply() {
	local wg_iface="$1" pub_iface="$2" prev_wg="${3:-}" prev_pub="${4:-}"
	if ! command_exists iptables; then
		warn "iptables not found; skipping FORWARD-chain compatibility rules for restrictive host firewalls (eg. Docker/OpenVPN). If clients handshake but cannot reach the internet, check 'iptables -L FORWARD -v' or 'nft list ruleset' manually for a conflicting DROP policy."
		return 0
	fi

	# Reconcile a changed interface: remove any previously-recorded compat
	# rule for a different wg/public interface pair first, so repair/update
	# never leaves a stale rule pointing at an old interface.
	if [ -n "$prev_wg" ] && [ -n "$prev_pub" ] && { [ "$prev_wg" != "$wg_iface" ] || [ "$prev_pub" != "$pub_iface" ]; }; then
		iptables -D FORWARD -i "$prev_wg" -o "$prev_pub" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -i "$prev_pub" -o "$prev_wg" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
		if command_exists ip6tables; then
			ip6tables -D FORWARD -i "$prev_wg" -o "$prev_pub" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
			ip6tables -D FORWARD -i "$prev_pub" -o "$prev_wg" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
		fi
	fi

	iptables -C FORWARD -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		|| iptables -I FORWARD 1 -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT
	iptables -C FORWARD -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		|| iptables -I FORWARD 1 -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT

	if command_exists ip6tables; then
		ip6tables -C FORWARD -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
			|| ip6tables -I FORWARD 1 -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
		ip6tables -C FORWARD -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
			|| ip6tables -I FORWARD 1 -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	fi

	{
		echo "compat_wg_iface=${wg_iface}"
		echo "compat_pub_iface=${pub_iface}"
	} >>"$WGVPN_FW_STATE"
}

# fw_compat_forward_remove: removes only the two project-owned compatibility
# rules recorded in $WGVPN_FW_STATE. Idempotent - safe to call when they
# were never installed (eg. iptables wasn't present) or already removed.
fw_compat_forward_remove() {
	[ -f "$WGVPN_FW_STATE" ] || return 0
	command_exists iptables || return 0
	local wg_iface pub_iface
	wg_iface="$(sed -n 's/^compat_wg_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	pub_iface="$(sed -n 's/^compat_pub_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	[ -n "$wg_iface" ] && [ -n "$pub_iface" ] || return 0

	iptables -D FORWARD -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	if command_exists ip6tables; then
		ip6tables -D FORWARD -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
		ip6tables -D FORWARD -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	fi
}

# fw_compat_forward_status <wg_iface>: prints "present" or "absent" depending
# on whether BOTH project-owned compatibility rules currently exist in the
# host's real iptables FORWARD chain. Prints "unavailable" if iptables isn't
# installed (nothing to check/fix via this mechanism).
fw_compat_forward_status() {
	local wg_iface="$1" pub_iface="${2:-}"
	command_exists iptables || { echo "unavailable"; return 0; }
	if [ -z "$pub_iface" ]; then
		pub_iface="$(sed -n 's/^compat_pub_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	fi
	[ -n "$pub_iface" ] || { echo "absent"; return 0; }
	if iptables -C FORWARD -i "$wg_iface" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		&& iptables -C FORWARD -i "$pub_iface" -o "$wg_iface" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null; then
		echo "present"
	else
		echo "absent"
	fi
}

# fw_host_forward_policy: prints the effective default policy of the host's
# real iptables FORWARD chain (ACCEPT/DROP/REJECT), or "unknown" if it
# cannot be determined (eg. iptables not installed).
fw_host_forward_policy() {
	command_exists iptables || { echo "unknown"; return 0; }
	iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/{print $3; found=1} END{if(!found) print "unknown"}'
}

fw_nft_remove() {
	nft delete table inet "$WGVPN_NFT_TABLE" 2>/dev/null || true
	nft delete table inet "${WGVPN_NFT_TABLE}_fwd" 2>/dev/null || true
	nft delete table ip "${WGVPN_NFT_TABLE}_nat" 2>/dev/null || true
	nft delete table ip6 "${WGVPN_NFT_TABLE}_nat6" 2>/dev/null || true
}

fw_iptables_apply() {
	local port="$1" mode="$2" pub_iface="$3" v4_subnet="$4" v6_subnet="$5" isolation="${6:-1}"
	iptables -C INPUT -p udp --dport "$port" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		|| iptables -I INPUT -p udp --dport "$port" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT

	# Insert accept rules first so that, if isolation is enabled, the DROP rule
	# inserted afterwards ends up ABOVE them (iptables -I always inserts at the
	# top), guaranteeing wg0<->wg0 traffic is evaluated against DROP first.
	iptables -C FORWARD -i "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		|| iptables -I FORWARD -i "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT
	iptables -C FORWARD -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
		|| iptables -I FORWARD -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT
	if [ "$isolation" = "1" ]; then
		iptables -C FORWARD -i "$WGVPN_IFACE" -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j DROP 2>/dev/null \
			|| iptables -I FORWARD -i "$WGVPN_IFACE" -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j DROP
	fi

	if [ "$mode" = "nat" ]; then
		iptables -t nat -C POSTROUTING -s "$v4_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE 2>/dev/null \
			|| iptables -t nat -A POSTROUTING -s "$v4_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE

		if [ -n "$v6_subnet" ] && command_exists ip6tables; then
			ip6tables -t nat -C POSTROUTING -s "$v6_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE 2>/dev/null \
				|| ip6tables -t nat -A POSTROUTING -s "$v6_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE
		fi
	fi

	{
		echo "port=${port}"
		echo "mode=${mode}"
		echo "pub_iface=${pub_iface}"
		echo "v4_subnet=${v4_subnet}"
		echo "v6_subnet=${v6_subnet}"
	} >>"$WGVPN_FW_STATE"
}

fw_iptables_remove() {
	local port mode pub_iface v4_subnet v6_subnet
	port="$(sed -n 's/^port=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	mode="$(sed -n 's/^mode=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	pub_iface="$(sed -n 's/^pub_iface=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	v4_subnet="$(sed -n 's/^v4_subnet=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"
	v6_subnet="$(sed -n 's/^v6_subnet=//p' "$WGVPN_FW_STATE" 2>/dev/null | head -n1)"

	[ -n "$port" ] && iptables -D INPUT -p udp --dport "$port" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i "$WGVPN_IFACE" -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j DROP 2>/dev/null || true
	iptables -D FORWARD -i "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null || true

	if [ "$mode" = "nat" ] && [ -n "$v4_subnet" ] && [ -n "$pub_iface" ]; then
		iptables -t nat -D POSTROUTING -s "$v4_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE 2>/dev/null || true
		if [ -n "$v6_subnet" ] && command_exists ip6tables; then
			ip6tables -t nat -D POSTROUTING -s "$v6_subnet" -o "$pub_iface" -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE 2>/dev/null || true
		fi
	fi
}

# fw_remove: removes only project-owned rules, per the recorded backend.
fw_remove() {
	local backend="none"
	if [ -f "$WGVPN_FW_STATE" ]; then backend="$(sed -n 's/^backend=//p' "$WGVPN_FW_STATE")"; fi
	case "$backend" in
		nftables) fw_nft_remove ;;
		iptables) fw_iptables_remove ;;
	esac
	# The FORWARD-chain compatibility rules are installed via `iptables`
	# regardless of which backend was chosen above for the project's own
	# dedicated tables, so they're always removed here too.
	fw_compat_forward_remove
	if [ -f "$WGVPN_FW_STATE" ] && grep -q '^ufw=1' "$WGVPN_FW_STATE" && command_exists ufw; then
		local port
		port="$(json_get "$WGVPN_CONF" wg_port)"
		[ -n "$port" ] && ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
	fi
	rm -f "$WGVPN_FW_STATE"
}

fw_status_report() {
	local backend
	backend="$(fw_detect_backend)"
	echo "backend=${backend}"
	if [ "$backend" = "nftables" ]; then
		nft list table inet "$WGVPN_NFT_TABLE" 2>/dev/null | grep -q "$WGVPN_FW_COMMENT" && echo "port_rule=present" || echo "port_rule=absent"
		nft list table ip "${WGVPN_NFT_TABLE}_nat" 2>/dev/null | grep -q "$WGVPN_FW_COMMENT" && echo "nat_rule=present" || echo "nat_rule=absent"
		nft list table inet "${WGVPN_NFT_TABLE}_fwd" 2>/dev/null | grep -q "$WGVPN_FW_COMMENT" && echo "forward_rule=present" || echo "forward_rule=absent"
	elif [ "$backend" = "iptables" ]; then
		iptables -C INPUT -p udp -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null && echo "port_rule=present" || echo "port_rule=absent"
		iptables -t nat -C POSTROUTING -m comment --comment "$WGVPN_FW_COMMENT" -j MASQUERADE 2>/dev/null && echo "nat_rule=present" || echo "nat_rule=absent"
		{ iptables -C FORWARD -i "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null \
			|| iptables -C FORWARD -o "$WGVPN_IFACE" -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null; } \
			&& echo "forward_rule=present" || echo "forward_rule=absent"
	fi
	echo "host_forward_policy=$(fw_host_forward_policy)"
	echo "compat_forward_rule=$(fw_compat_forward_status "$WGVPN_IFACE")"
	fw_ufw_active && echo "ufw=active" || echo "ufw=inactive"
}
