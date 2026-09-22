#!/usr/bin/env bash
# peers.sh - road-warrior client lifecycle management
# shellcheck shell=bash

if [ -n "${WGVPN_PEERS_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_PEERS_LOADED=1

peer_file() { echo "${WGVPN_CLIENTS_DIR}/${1}.json"; }

peer_exists() { [ -f "$(peer_file "$1")" ]; }

# peer_add <name> [mode] [ipv4_nets] [ipv6_nets] [dns] [keepalive]
# Creates key material + state; regenerates server config; applies live.
peer_add() {
	local name="$1" mode="${2:-}" v4nets="${3:-}" v6nets="${4:-}" dns="${5:-}" keepalive="${6:-}"

	valid_peer_name "$name" || die "Invalid client name: '$name'. Use letters, digits, '-', '_' (max 32 chars, must start alphanumeric)."
	if peer_exists "$name"; then die "A client named '$name' already exists."; fi

	mkdir -p "$WGVPN_CLIENTS_DIR"

	local v4_subnet v6_subnet
	v4_subnet="$(json_get "$WGVPN_CONF" ipv4_subnet)"
	v6_subnet="$(json_get "$WGVPN_CONF" ipv6_subnet)"
	if [ -z "$mode" ]; then mode="$(json_get "$WGVPN_CONF" default_mode)"; fi
	if [ -z "$dns" ]; then dns="$(json_get "$WGVPN_CONF" default_dns)"; fi
	if [ -z "$keepalive" ]; then keepalive="$(json_get "$WGVPN_CONF" default_keepalive)"; fi

	local addr4 addr6=""
	addr4="$(alloc_next_ipv4 "$v4_subnet" "$WGVPN_CLIENTS_DIR")" || die "No free IPv4 addresses remain in ${v4_subnet}."
	if routing_mode_requires_ipv6 "$mode" || [ "$mode" = "full-dual" ] || [ "$mode" = "split-dual" ]; then
		if [ -n "$v6_subnet" ]; then
			addr6="$(alloc_next_ipv6 "$v6_subnet" "$WGVPN_CLIENTS_DIR")" || die "No free IPv6 addresses remain."
		fi
	fi

	local privkey pubkey psk
	privkey="$(wg_genkey)"
	pubkey="$(wg_pubkey "$privkey")"
	psk="$(wg_genpsk)"

	local allowed
	allowed="$(routing_mode_allowed_ips "$mode" "$v4nets" "$v6nets")" || die "Invalid connection mode: $mode"

	local f
	f="$(peer_file "$name")"
	jq -n \
		--arg name "$name" \
		--arg private_key "$privkey" \
		--arg public_key "$pubkey" \
		--arg preshared_key "$psk" \
		--arg vpn_ipv4 "$addr4" \
		--arg vpn_ipv6 "$addr6" \
		--arg mode "$mode" \
		--arg allowed_ips "$allowed" \
		--arg dns "$dns" \
		--arg keepalive "$keepalive" \
		--arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		'{name:$name, enabled:true, private_key:$private_key, public_key:$public_key,
		  preshared_key:$preshared_key, vpn_ipv4:$vpn_ipv4, vpn_ipv6:$vpn_ipv6,
		  mode:$mode, allowed_ips:$allowed_ips, dns:$dns, keepalive:$keepalive, created:$created}' \
		| atomic_write "$f" 0600

	wg_render_server_config
	wg_apply_peer_live
	ok "Client '${name}' added (VPN address: ${addr4}${addr6:+, $addr6})."
}

peer_delete() {
	local name="$1" f pubkey
	f="$(peer_file "$name")"
	[ -f "$f" ] || die "No such client: $name"
	pubkey="$(json_get "$f" public_key)"
	wg_revoke_peer_live "$pubkey"
	rm -f -- "$f"
	wg_render_server_config
	ok "Client '${name}' deleted and revoked."
}

peer_enable() {
	local name="$1" f
	f="$(peer_file "$name")"
	[ -f "$f" ] || die "No such client: $name"
	json_set "$f" enabled true raw
	wg_render_server_config
	wg_apply_peer_live
	ok "Client '${name}' enabled."
}

peer_disable() {
	local name="$1" f pubkey
	f="$(peer_file "$name")"
	[ -f "$f" ] || die "No such client: $name"
	pubkey="$(json_get "$f" public_key)"
	json_set "$f" enabled false raw
	wg_revoke_peer_live "$pubkey"
	wg_render_server_config
	ok "Client '${name}' disabled."
}

peer_list() {
	local f name enabled ip4
	[ -d "$WGVPN_CLIENTS_DIR" ] || return 0
	printf '%-20s %-10s %-16s\n' "NAME" "STATUS" "VPN ADDRESS"
	for f in "$WGVPN_CLIENTS_DIR"/*.json; do
		[ -e "$f" ] || continue
		name="$(json_get "$f" name)"
		enabled="$(json_get "$f" enabled)"
		ip4="$(json_get "$f" vpn_ipv4)"
		[ "$enabled" = "true" ] && enabled="enabled" || enabled="disabled"
		printf '%-20s %-10s %-16s\n' "$name" "$enabled" "$ip4"
	done
}

peer_show() {
	local name="$1" f
	f="$(peer_file "$name")"
	[ -f "$f" ] || die "No such client: $name"
	jq 'del(.private_key, .preshared_key)' "$f"
}

# peer_client_config <name>: renders a full .conf file for distribution to the client device.
peer_client_config() {
	local name="$1" f
	f="$(peer_file "$name")"
	[ -f "$f" ] || die "No such client: $name"

	local privkey psk addr4 addr6 dns keepalive allowed mtu
	local srv_pubkey endpoint
	privkey="$(json_get "$f" private_key)"
	psk="$(json_get "$f" preshared_key)"
	addr4="$(json_get "$f" vpn_ipv4)"
	addr6="$(json_get "$f" vpn_ipv6)"
	dns="$(json_get "$f" dns)"
	keepalive="$(json_get "$f" keepalive)"
	allowed="$(json_get "$f" allowed_ips)"
	mtu="$(json_get "$WGVPN_CONF" mtu)"
	srv_pubkey="$(json_get "$WGVPN_CONF" server_public_key)"
	endpoint="$(json_get "$WGVPN_CONF" endpoint)"

	local addr="$addr4"
	if [ -n "$addr6" ]; then addr="${addr}/32,${addr6}/128"; else addr="${addr}/32"; fi

	echo "[Interface]"
	echo "PrivateKey = ${privkey}"
	echo "Address = ${addr}"
	if [ -n "$dns" ]; then echo "DNS = ${dns}"; fi
	if [ -n "$mtu" ]; then echo "MTU = ${mtu}"; fi
	echo
	echo "[Peer]"
	echo "PublicKey = ${srv_pubkey}"
	if [ -n "$psk" ]; then echo "PresharedKey = ${psk}"; fi
	echo "AllowedIPs = ${allowed}"
	echo "Endpoint = ${endpoint}"
	if [ -n "$keepalive" ] && [ "$keepalive" != "0" ]; then echo "PersistentKeepalive = ${keepalive}"; fi
}

peer_export() {
	local name="$1" out="${2:-}"
	if [ -z "$out" ]; then out="./${name}.conf"; fi
	peer_client_config "$name" | atomic_write "$out" 0600
	ok "Exported client config to ${out}"
}

peer_qr() {
	local name="$1"
	command_exists qrencode || die "qrencode is not installed."
	peer_client_config "$name" | qrencode -t ansiutf8
}
