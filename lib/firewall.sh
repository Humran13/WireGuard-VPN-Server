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

	if [ "$backend" = "nftables" ]; then
		echo "backend=nftables" >"$WGVPN_FW_STATE"
		fw_nft_apply "$port" "$mode" "$pub_iface" "$v4_subnet" "$v6_subnet" "$isolation"
	else
		echo "backend=iptables" >"$WGVPN_FW_STATE"
		fw_iptables_apply "$port" "$mode" "$pub_iface" "$v4_subnet" "$v6_subnet" "$isolation"
	fi

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
	elif [ "$backend" = "iptables" ]; then
		iptables -C INPUT -p udp -m comment --comment "$WGVPN_FW_COMMENT" -j ACCEPT 2>/dev/null && echo "port_rule=present" || echo "port_rule=absent"
	fi
	fw_ufw_active && echo "ufw=active" || echo "ufw=inactive"
}
