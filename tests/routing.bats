#!/usr/bin/env bats

setup() {
	load 'test_helper.bash'
	load_libs
	CLIENTS_DIR="${BATS_TEST_TMPDIR}/clients"
	mkdir -p "$CLIENTS_DIR"
}

@test "routing_mode_allowed_ips full4" {
	run routing_mode_allowed_ips full4
	[ "$status" -eq 0 ]
	[ "$output" = "0.0.0.0/0" ]
}

@test "routing_mode_allowed_ips full6" {
	run routing_mode_allowed_ips full6
	[ "$output" = "::/0" ]
}

@test "routing_mode_allowed_ips full-dual" {
	run routing_mode_allowed_ips full-dual
	[ "$output" = "0.0.0.0/0,::/0" ]
}

@test "routing_mode_allowed_ips split4 passes through networks" {
	run routing_mode_allowed_ips split4 "10.1.0.0/24,10.2.0.0/24"
	[ "$output" = "10.1.0.0/24,10.2.0.0/24" ]
}

@test "routing_mode_allowed_ips split-dual combines v4 and v6" {
	run routing_mode_allowed_ips split-dual "10.1.0.0/24" "fd00::/64"
	[ "$output" = "10.1.0.0/24,fd00::/64" ]
}

@test "routing_mode_allowed_ips rejects unknown mode" {
	run routing_mode_allowed_ips bogus
	[ "$status" -ne 0 ]
}

@test "routing_mode_requires_ipv6 correctly flags modes" {
	run routing_mode_requires_ipv6 full6; [ "$status" -eq 0 ]
	run routing_mode_requires_ipv6 split6; [ "$status" -eq 0 ]
	run routing_mode_requires_ipv6 full-dual; [ "$status" -eq 0 ]
	run routing_mode_requires_ipv6 full4; [ "$status" -ne 0 ]
}

@test "routing_validate_cidr_list accepts valid and rejects invalid" {
	run routing_validate_cidr_list "10.0.0.0/24,10.1.0.0/24" 4
	[ "$status" -eq 0 ]
	run routing_validate_cidr_list "10.0.0.0/24,not-a-cidr" 4
	[ "$status" -ne 0 ]
	run routing_validate_cidr_list "" 4
	[ "$status" -ne 0 ]
}

@test "routing_check_overlap_ipv4_csv finds internal overlap" {
	run routing_check_overlap_ipv4_csv "10.0.0.0/24,10.0.0.128/25"
	[ "$status" -eq 0 ]
	run routing_check_overlap_ipv4_csv "10.0.0.0/24,10.1.0.0/24"
	[ "$status" -ne 0 ]
}

@test "alloc_next_ipv4 skips server address and allocates sequentially" {
	run alloc_next_ipv4 "10.66.66.0/24" "$CLIENTS_DIR"
	[ "$status" -eq 0 ]
	[ "$output" = "10.66.66.2" ]
}

@test "alloc_next_ipv4 avoids addresses already in use" {
	jq -n '{name:"a", vpn_ipv4:"10.66.66.2"}' >"${CLIENTS_DIR}/a.json"
	run alloc_next_ipv4 "10.66.66.0/24" "$CLIENTS_DIR"
	[ "$status" -eq 0 ]
	[ "$output" = "10.66.66.3" ]
}

@test "alloc_next_ipv4 detects duplicate allocations across many clients" {
	for i in $(seq 2 10); do
		jq -n --arg ip "10.66.66.${i}" '{name:"c", vpn_ipv4:$ip}' >"${CLIENTS_DIR}/c${i}.json"
	done
	run alloc_next_ipv4 "10.66.66.0/24" "$CLIENTS_DIR"
	[ "$status" -eq 0 ]
	[ "$output" = "10.66.66.11" ]
}

@test "routing_overlaps_existing_peer_routes detects overlap between site peers" {
	local dir="${BATS_TEST_TMPDIR}/peers"
	mkdir -p "$dir"
	jq -n '{name:"siteA", allowed_ips:"192.168.10.0/24"}' >"${dir}/siteA.json"
	run routing_overlaps_existing_peer_routes "192.168.10.0/25" "$dir"
	[ "$status" -eq 0 ]
	run routing_overlaps_existing_peer_routes "192.168.20.0/24" "$dir"
	[ "$status" -ne 0 ]
}
