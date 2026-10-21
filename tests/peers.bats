#!/usr/bin/env bats
# Regression coverage for lib/peers.sh, in particular the use_psk setting:
# peer_add() previously generated and stored a preshared key unconditionally,
# ignoring the server's use_psk=false configuration entirely.

setup() {
	load 'test_helper.bash'
	source "${REPO_ROOT}/lib/common.sh"
	source "${REPO_ROOT}/lib/validate.sh"
	source "${REPO_ROOT}/lib/routing.sh"
	source "${REPO_ROOT}/lib/wireguard.sh"
	source "${REPO_ROOT}/lib/peers.sh"

	export WGVPN_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	export WGVPN_CLIENTS_DIR="${WGVPN_STATE_DIR}/clients"
	export WGVPN_CONF="${WGVPN_STATE_DIR}/config.json"
	export WGVPN_WG_DIR="${BATS_TEST_TMPDIR}/wg"
	export WGVPN_IFACE="wg0"
	mkdir -p "$WGVPN_CLIENTS_DIR" "$WGVPN_WG_DIR"
}

write_conf() {
	# $1 = "true" or "false" for use_psk
	jq -n --argjson use_psk "$1" '{
		wg_port: "51820", ipv4_subnet: "10.66.66.0/24", ipv6_subnet: "",
		ipv6_enabled: false, default_mode: "full4", default_dns: "1.1.1.1",
		default_keepalive: "25", endpoint: "203.0.113.10:51820",
		forward_mode: "nat", public_iface: "eth0", mtu: "1420",
		use_psk: $use_psk, client_isolation: true,
		server_private_key: "", server_public_key: "SERVERPUBKEYPLACEHOLDER0000000000000000000=",
		server_ipv4: "10.66.66.1/24", server_ipv6: "", version: "test"
	}' >"$WGVPN_CONF"
}

@test "peer_add generates a preshared key when use_psk=true" {
	write_conf true
	run peer_add alice
	[ "$status" -eq 0 ]
	local psk
	psk="$(json_get "${WGVPN_CLIENTS_DIR}/alice.json" preshared_key)"
	[ -n "$psk" ]
}

@test "peer_add does NOT generate a preshared key when use_psk=false" {
	write_conf false
	run peer_add alice
	[ "$status" -eq 0 ]
	local psk
	psk="$(json_get "${WGVPN_CLIENTS_DIR}/alice.json" preshared_key)"
	[ -z "$psk" ]
}

@test "generated client config omits PresharedKey when use_psk=false" {
	write_conf false
	peer_add alice
	run peer_client_config alice
	[ "$status" -eq 0 ]
	[[ "$output" != *"PresharedKey"* ]]
	[[ "$output" == *"AllowedIPs = 0.0.0.0/0"* ]]
}

@test "generated client config includes PresharedKey when use_psk=true" {
	write_conf true
	peer_add alice
	run peer_client_config alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"PresharedKey = "* ]]
}

@test "peer_add fails clearly for split4 with no networks, instead of writing a broken client" {
	write_conf true
	run peer_add bob split4
	[ "$status" -ne 0 ]
	[ ! -f "${WGVPN_CLIENTS_DIR}/bob.json" ]
}

@test "rendered server config's [Peer] block matches use_psk setting" {
	write_conf false
	peer_add alice
	run wg_render_server_config
	[ "$status" -eq 0 ]
	run cat "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
	[[ "$output" != *"PresharedKey"* ]]
	[[ "$output" == *"[Peer]"* ]]
}
