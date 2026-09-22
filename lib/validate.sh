#!/usr/bin/env bash
# validate.sh - input validation helpers (pure functions, no side effects)
# shellcheck shell=bash

if [ -n "${WGVPN_VALIDATE_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_VALIDATE_LOADED=1

# valid_ipv4 <addr>
valid_ipv4() {
	local ip="$1" o
	[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
		[[ "$o" =~ ^0[0-9] ]] && return 1
		[ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
	done
	return 0
}

# valid_ipv6 <addr>  (delegates to a conservative regex + shell expansion trick)
valid_ipv6() {
	local ip="$1"
	[ -z "$ip" ] && return 1
	# reject obviously invalid characters
	[[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
	# must contain at least one colon
	[[ "$ip" == *:* ]] || return 1
	# no more than one "::"
	local double_count
	double_count=$(grep -o "::" <<<"$ip" | wc -l)
	[ "$double_count" -gt 1 ] && return 1
	# no more than 8 groups, and if no "::" must be exactly 8
	local ngroups
	ngroups=$(awk -F: '{print NF}' <<<"${ip//::/:}")
	if [[ "$ip" == *::* ]]; then
		[ "$ngroups" -le 8 ] || return 1
	else
		[ "$ngroups" -eq 8 ] || return 1
	fi
	# each group max 4 hex digits
	local g
	IFS=: read -ra parts <<<"${ip//::/:PLACEHOLDER:}"
	for g in "${parts[@]}"; do
		[ "$g" = "PLACEHOLDER" ] && continue
		[ -z "$g" ] && continue
		[[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
	done
	return 0
}

# valid_ipv4_cidr <cidr>
valid_ipv4_cidr() {
	local cidr="$1" ip prefix
	[[ "$cidr" == */* ]] || return 1
	ip="${cidr%/*}"
	prefix="${cidr#*/}"
	valid_ipv4 "$ip" || return 1
	[[ "$prefix" =~ ^[0-9]+$ ]] || return 1
	[ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

# valid_ipv6_cidr <cidr>
valid_ipv6_cidr() {
	local cidr="$1" ip prefix
	[[ "$cidr" == */* ]] || return 1
	ip="${cidr%/*}"
	prefix="${cidr#*/}"
	valid_ipv6 "$ip" || return 1
	[[ "$prefix" =~ ^[0-9]+$ ]] || return 1
	[ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ]
}

# valid_port <port>
valid_port() {
	local p="$1"
	[[ "$p" =~ ^[0-9]+$ ]] || return 1
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# valid_peer_name <name> - DNS-safe, filesystem-safe client identifier
valid_peer_name() {
	local n="$1"
	[ -n "$n" ] || return 1
	[ "${#n}" -le 32 ] || return 1
	[[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

# valid_hostname <host> - RFC1123 hostname or FQDN
valid_hostname() {
	local h="$1"
	[ -n "$h" ] || return 1
	[ "${#h}" -le 253 ] || return 1
	[[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

# valid_endpoint_host <value> - IPv4, IPv6 (bracketed or bare), or hostname
valid_endpoint_host() {
	local v="$1"
	if [ -z "$v" ]; then return 1; fi
	if [[ "$v" == \[*\] ]]; then
		v="${v#\[}"; v="${v%\]}"
		if valid_ipv6 "$v"; then return 0; fi
		return 1
	fi
	if valid_ipv4 "$v"; then return 0; fi
	if valid_ipv6 "$v"; then return 0; fi
	if valid_hostname "$v"; then return 0; fi
	return 1
}

# valid_base64_key <key> - WireGuard key: 44 base64 chars ending in '='
valid_base64_key() {
	local k="$1"
	[[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# valid_mtu <n>
valid_mtu() {
	local n="$1"
	[[ "$n" =~ ^[0-9]+$ ]] || return 1
	[ "$n" -ge 576 ] && [ "$n" -le 9000 ]
}

# valid_keepalive <n> (0 disables)
valid_keepalive() {
	local n="$1"
	[[ "$n" =~ ^[0-9]+$ ]] || return 1
	[ "$n" -ge 0 ] && [ "$n" -le 3600 ]
}

# ---- CIDR math (IPv4) ------------------------------------------------------

# ipv4_to_int <ip> -> echoes integer
ipv4_to_int() {
	local ip="$1" a b c d
	IFS=. read -r a b c d <<<"$ip"
	echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ipv4() {
	local i="$1"
	printf '%d.%d.%d.%d\n' $(( (i >> 24) & 255 )) $(( (i >> 16) & 255 )) $(( (i >> 8) & 255 )) $(( i & 255 ))
}

# cidr_network_range <cidr> -> prints "start_int end_int"
cidr_ipv4_range() {
	local cidr="$1" ip prefix ip_int mask start end
	ip="${cidr%/*}"; prefix="${cidr#*/}"
	ip_int=$(ipv4_to_int "$ip")
	if [ "$prefix" -eq 0 ]; then
		mask=0
	else
		mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
	fi
	start=$(( ip_int & mask ))
	end=$(( start | (0xFFFFFFFF ^ mask) & 0xFFFFFFFF ))
	echo "$start $end"
}

# cidrs_overlap_ipv4 <cidr1> <cidr2>
cidrs_overlap_ipv4() {
	local r1 r2 s1 e1 s2 e2
	r1="$(cidr_ipv4_range "$1")"; r2="$(cidr_ipv4_range "$2")"
	read -r s1 e1 <<<"$r1"
	read -r s2 e2 <<<"$r2"
	[ "$s1" -le "$e2" ] && [ "$s2" -le "$e1" ]
}

# ipv4_in_cidr <ip> <cidr>
ipv4_in_cidr() {
	local ip_int s e r
	ip_int=$(ipv4_to_int "$1")
	r="$(cidr_ipv4_range "$2")"
	read -r s e <<<"$r"
	[ "$ip_int" -ge "$s" ] && [ "$ip_int" -le "$e" ]
}
