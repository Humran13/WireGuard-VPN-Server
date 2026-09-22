#!/usr/bin/env bash
# routing.sh - connection/routing mode logic, AllowedIPs generation, address allocation
# shellcheck shell=bash

if [ -n "${WGVPN_ROUTING_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_ROUTING_LOADED=1

# Modes:
#  full4        - 0.0.0.0/0
#  full6        - ::/0  (requires server IPv6)
#  full-dual    - 0.0.0.0/0, ::/0
#  split4       - admin-provided IPv4 CIDR list
#  split6       - admin-provided IPv6 CIDR list
#  split-dual   - admin-provided IPv4 + IPv6 CIDR list
#  site2site    - handled separately via routing_site_allowed_ips

# routing_mode_allowed_ips <mode> <ipv4_networks_csv> <ipv6_networks_csv>
# Prints the AllowedIPs value for a road-warrior client's config, given the mode.
routing_mode_allowed_ips() {
	local mode="$1" v4="${2:-}" v6="${3:-}"
	case "$mode" in
		full4) echo "0.0.0.0/0" ;;
		full6) echo "::/0" ;;
		full-dual) echo "0.0.0.0/0,::/0" ;;
		split4) echo "$v4" ;;
		split6) echo "$v6" ;;
		split-dual)
			if [ -n "$v4" ] && [ -n "$v6" ]; then
				echo "${v4},${v6}"
			else
				echo "${v4}${v6}"
			fi
			;;
		*) return 1 ;;
	esac
}

# routing_mode_requires_ipv6 <mode>
routing_mode_requires_ipv6() {
	case "$1" in
		full6|full-dual|split6) return 0 ;;
		*) return 1 ;;
	esac
}

# routing_validate_cidr_list <csv> <family: 4|6>
routing_validate_cidr_list() {
	local csv="$1" family="$2" c
	IFS=',' read -ra parts <<<"$csv"
	[ "${#parts[@]}" -gt 0 ] || return 1
	for c in "${parts[@]}"; do
		c="$(echo -n "$c" | xargs)"
		if [ -z "$c" ]; then return 1; fi
		if [ "$family" = "4" ]; then
			valid_ipv4_cidr "$c" || return 1
		else
			valid_ipv6_cidr "$c" || return 1
		fi
	done
	return 0
}

# routing_check_overlap_csv <csv> <family> : checks the list itself has no internal overlaps (IPv4 only, deep check)
routing_check_overlap_ipv4_csv() {
	local csv="$1"
	IFS=',' read -ra parts <<<"$csv"
	local i j
	for ((i=0; i<${#parts[@]}; i++)); do
		for ((j=i+1; j<${#parts[@]}; j++)); do
			if cidrs_overlap_ipv4 "${parts[$i]}" "${parts[$j]}"; then
				echo "${parts[$i]} ${parts[$j]}"
				return 0
			fi
		done
	done
	return 1
}

# --- Address allocation ------------------------------------------------------

# alloc_next_ipv4 <subnet_cidr> <clients_dir>: finds the next free host address.
# Reserves .1 for the server. Returns the address or empty on exhaustion.
alloc_next_ipv4() {
	local subnet="$1" clients_dir="$2"
	local base_int range_end ip_int candidate used
	read -r base_int range_end <<<"$(cidr_ipv4_range "$subnet")"
	local used_list=()
	if [ -d "$clients_dir" ]; then
		local f a
		for f in "$clients_dir"/*.json; do
			[ -e "$f" ] || continue
			a="$(json_get "$f" vpn_ipv4)"
			if [ -n "$a" ]; then used_list+=("$(ipv4_to_int "$a")"); fi
		done
	fi
	for ((ip_int=base_int+2; ip_int<range_end; ip_int++)); do
		used=0
		for candidate in "${used_list[@]}"; do
			if [ "$candidate" -eq "$ip_int" ]; then used=1; break; fi
		done
		if [ "$used" -eq 0 ]; then
			int_to_ipv4 "$ip_int"
			return 0
		fi
	done
	return 1
}

# alloc_next_ipv6 <subnet_cidr> <clients_dir>: sequential allocation using the low 32 bits.
alloc_next_ipv6() {
	local subnet="$1" clients_dir="$2"
	local prefix="${subnet%/*}"
	local base="${prefix%::*}"
	local n used_list=() f a suffix
	if [ -d "$clients_dir" ]; then
		for f in "$clients_dir"/*.json; do
			[ -e "$f" ] || continue
			a="$(json_get "$f" vpn_ipv6)"
			if [ -n "$a" ]; then used_list+=("$a"); fi
		done
	fi
	for ((n=2; n<65534; n++)); do
		suffix="$(printf '%x' "$n")"
		local candidate="${base}::${suffix}"
		local match=0 u
		for u in "${used_list[@]}"; do
			if [ "$u" = "$candidate" ]; then match=1; break; fi
		done
		if [ "$match" -eq 0 ]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

# routing_overlaps_existing_peer_routes <csv> <site_peers_dir> [exclude_name]
# Prevents overlapping AllowedIPs between site-to-site peers.
routing_overlaps_existing_peer_routes() {
	local csv="$1" dir="$2" exclude="${3:-}"
	IFS=',' read -ra new_cidrs <<<"$csv"
	local f name existing_csv e n
	[ -d "$dir" ] || return 1
	for f in "$dir"/*.json; do
		[ -e "$f" ] || continue
		name="$(json_get "$f" name)"
		if [ "$name" = "$exclude" ]; then continue; fi
		existing_csv="$(json_get "$f" allowed_ips)"
		IFS=',' read -ra existing_cidrs <<<"$existing_csv"
		for n in "${new_cidrs[@]}"; do
			if [[ "$n" == *:* ]]; then continue; fi
			for e in "${existing_cidrs[@]}"; do
				if [[ "$e" == *:* ]]; then continue; fi
				if cidrs_overlap_ipv4 "$n" "$e"; then
					echo "$n overlaps $e (peer: $name)"
					return 0
				fi
			done
		done
	done
	return 1
}
