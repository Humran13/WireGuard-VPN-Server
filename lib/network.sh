#!/usr/bin/env bash
# network.sh - interface detection, public IP detection, IPv6 capability
# shellcheck shell=bash

if [ -n "${WGVPN_NETWORK_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_NETWORK_LOADED=1

# net_default_iface: prints the interface used for the default IPv4 route.
net_default_iface() {
	local iface
	iface="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
	if [ -z "$iface" ]; then
		iface="$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
	fi
	if [ -z "$iface" ]; then
		# fallback: first non-loopback UP interface
		iface="$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1)"
	fi
	echo "$iface"
}

# net_default_iface6: prints the interface used for the default IPv6 route.
net_default_iface6() {
	ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# net_ipv6_available: returns 0 if the host has a usable global IPv6 address + default route.
net_ipv6_available() {
	local iface addr
	iface="$(net_default_iface6)"
	[ -n "$iface" ] || return 1
	addr="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | head -n1)"
	[ -n "$addr" ] || return 1
	return 0
}

# net_public_ipv4: best-effort public IPv4 detection with multiple fallbacks.
net_public_ipv4() {
	local ip svc
	local services=(
		"https://api.ipify.org"
		"https://ifconfig.me/ip"
		"https://icanhazip.com"
	)
	for svc in "${services[@]}"; do
		ip="$(curl -4 -fsSL --max-time 4 "$svc" 2>/dev/null | tr -d ' \t\n\r')"
		if [ -n "$ip" ] && valid_ipv4 "$ip"; then
			echo "$ip"
			return 0
		fi
	done
	# local fallback: primary address on default iface
	local iface
	iface="$(net_default_iface)"
	if [ -n "$iface" ]; then
		ip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
		if [ -n "$ip" ]; then echo "$ip"; return 0; fi
	fi
	return 1
}

# net_public_ipv6: best-effort public IPv6 detection.
net_public_ipv6() {
	local ip svc
	local services=("https://api64.ipify.org" "https://ifconfig.me/ip")
	net_ipv6_available || return 1
	for svc in "${services[@]}"; do
		ip="$(curl -6 -fsSL --max-time 4 "$svc" 2>/dev/null | tr -d ' \t\n\r')"
		if [ -n "$ip" ] && valid_ipv6 "$ip"; then
			echo "$ip"
			return 0
		fi
	done
	return 1
}

# net_local_ipv4_cidrs: list CIDRs already routed on the host (to avoid VPN subnet collisions)
net_local_ipv4_cidrs() {
	ip -4 route show 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'
}

# net_subnet_collides <cidr>: 0 if candidate subnet overlaps an existing host route
net_subnet_collides() {
	local candidate="$1" existing
	while IFS= read -r existing; do
		if [ -z "$existing" ]; then continue; fi
		if cidrs_overlap_ipv4 "$candidate" "$existing"; then
			return 0
		fi
	done < <(net_local_ipv4_cidrs)
	return 1
}

# net_suggest_ipv4_subnet: pick a private /24 unlikely to collide.
net_suggest_ipv4_subnet() {
	local candidates=("10.66.66.0/24" "10.13.13.0/24" "10.8.0.0/24" "172.16.66.0/24" "192.168.99.0/24")
	local c
	for c in "${candidates[@]}"; do
		if ! net_subnet_collides "$c"; then
			echo "$c"
			return 0
		fi
	done
	echo "10.66.66.0/24"
}

# net_listen_udp_ok <port>: 0 if nothing else is already listening on that UDP port
net_port_in_use() {
	local port="$1"
	if command_exists ss; then
		ss -uln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}\$"
		return $?
	fi
	return 1
}

# --- sysctl (IP forwarding) -------------------------------------------------

# net_sysctl_enable_forwarding <ipv4: 0|1> <ipv6: 0|1>
net_sysctl_enable_forwarding() {
	local v4="$1" v6="${2:-0}"
	{
		echo "# Managed by wireguard-vpn-server. Do not edit by hand."
		if [ "$v4" = "1" ]; then echo "net.ipv4.ip_forward = 1"; fi
		if [ "$v6" = "1" ]; then echo "net.ipv6.conf.all.forwarding = 1"; fi
		true
	} | atomic_write "$WGVPN_SYSCTL_FILE" 0644
	sysctl -p "$WGVPN_SYSCTL_FILE" >/dev/null 2>&1 || warn "sysctl -p reported errors while applying forwarding settings."
}

net_sysctl_forwarding_status() {
	local v4 v6
	v4="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
	v6="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"
	echo "ipv4=${v4} ipv6=${v6}"
}

net_sysctl_remove() {
	rm -f "$WGVPN_SYSCTL_FILE"
}
