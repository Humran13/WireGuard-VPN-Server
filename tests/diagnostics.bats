#!/usr/bin/env bats
# Regression coverage for lib/diagnostics.sh's per-client connectivity
# report (diag_client_report), used by both `wg-vpn diagnostics` and
# `wg-vpn test-client <name>`.

setup() {
	load 'test_helper.bash'
	source "${REPO_ROOT}/lib/common.sh"
	source "${REPO_ROOT}/lib/validate.sh"
	source "${REPO_ROOT}/lib/routing.sh"
	source "${REPO_ROOT}/lib/wireguard.sh"
	source "${REPO_ROOT}/lib/peers.sh"
	source "${REPO_ROOT}/lib/diagnostics.sh"

	export WGVPN_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	export WGVPN_CLIENTS_DIR="${WGVPN_STATE_DIR}/clients"
	export WGVPN_CONF="${WGVPN_STATE_DIR}/config.json"
	export WGVPN_WG_DIR="${BATS_TEST_TMPDIR}/wg"
	export WGVPN_IFACE="wg0_bats_test_$$"
	mkdir -p "$WGVPN_CLIENTS_DIR" "$WGVPN_WG_DIR"

	jq -n '{
		wg_port: "51820", ipv4_subnet: "10.66.66.0/24", ipv6_subnet: "",
		ipv6_enabled: false, default_mode: "full4", default_dns: "1.1.1.1",
		default_keepalive: "25", endpoint: "203.0.113.10:51820",
		forward_mode: "nat", public_iface: "eth0", mtu: "1420",
		use_psk: true, client_isolation: true,
		server_private_key: "", server_public_key: "X",
		server_ipv4: "10.66.66.1/24", server_ipv6: "", version: "test"
	}' >"$WGVPN_CONF"
}

@test "diag_human_bytes formats sizes the way wg show does" {
	run diag_human_bytes 0; [ "$output" = "0 B" ]
	run diag_human_bytes 512; [ "$output" = "512 B" ]
	run diag_human_bytes 2048; [[ "$output" == "2.00 KiB" ]]
	run diag_human_bytes 5242880; [[ "$output" == "5.00 MiB" ]]
}

@test "diag_client_report on an unconfigured client fails clearly" {
	run diag_client_report ghost
	[ "$status" -ne 0 ]
	[[ "$output" == *"not configured"* ]]
}

@test "diag_client_report on a freshly-added client reports configured/enabled/never-handshaken" {
	peer_add alice
	run diag_client_report alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"Configured: yes"* ]]
	[[ "$output" == *"Enabled: yes"* ]]
	[[ "$output" == *"Latest handshake: never"* ]]
	# No real wg0 device exists in this pure unit-test environment, so the
	# client can never be "loaded live" here - that path (and the "just
	# created, this is normal" vs. "stale, check firewall/endpoint"
	# interpretations once it IS live) is exercised for real with an
	# actual kernel WireGuard interface by tests/e2e/tunnel_test.sh.
	[[ "$output" == *"Loaded live: no"* ]]
}

@test "diag_client_report reports a disabled client distinctly" {
	peer_add alice
	peer_disable alice
	run diag_client_report alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"Enabled: no"* ]]
	[[ "$output" == *"disabled"* ]]
}

@test "diag_client_report never prints a private key or preshared key" {
	peer_add alice
	run diag_client_report alice
	[ "$status" -eq 0 ]
	local privkey psk
	privkey="$(json_get "${WGVPN_CLIENTS_DIR}/alice.json" private_key)"
	psk="$(json_get "${WGVPN_CLIENTS_DIR}/alice.json" preshared_key)"
	[[ "$output" != *"$privkey"* ]]
	[[ "$output" != *"$psk"* ]]
}
