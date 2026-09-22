#!/usr/bin/env bats

setup() {
	load 'test_helper.bash'
	load_libs
}

@test "valid_ipv4 accepts normal addresses" {
	run valid_ipv4 "192.168.1.1"
	[ "$status" -eq 0 ]
}

@test "valid_ipv4 accepts 0.0.0.0 and 255.255.255.255" {
	run valid_ipv4 "0.0.0.0"; [ "$status" -eq 0 ]
	run valid_ipv4 "255.255.255.255"; [ "$status" -eq 0 ]
}

@test "valid_ipv4 rejects out-of-range octets" {
	run valid_ipv4 "256.1.1.1"
	[ "$status" -ne 0 ]
}

@test "valid_ipv4 rejects leading zeros" {
	run valid_ipv4 "192.168.001.1"
	[ "$status" -ne 0 ]
}

@test "valid_ipv4 rejects malformed/hostile input" {
	run valid_ipv4 "1.2.3"
	[ "$status" -ne 0 ]
	run valid_ipv4 "1.2.3.4.5"
	[ "$status" -ne 0 ]
	run valid_ipv4 "; rm -rf /"
	[ "$status" -ne 0 ]
	run valid_ipv4 ""
	[ "$status" -ne 0 ]
	run valid_ipv4 "a.b.c.d"
	[ "$status" -ne 0 ]
}

@test "valid_ipv6 accepts standard forms" {
	run valid_ipv6 "::1"; [ "$status" -eq 0 ]
	run valid_ipv6 "fe80::1"; [ "$status" -eq 0 ]
	run valid_ipv6 "2001:db8::ff00:42:8329"; [ "$status" -eq 0 ]
	run valid_ipv6 "2001:0db8:0000:0000:0000:ff00:0042:8329"; [ "$status" -eq 0 ]
}

@test "valid_ipv6 rejects malformed/hostile input" {
	run valid_ipv6 "not:an:address"
	[ "$status" -ne 0 ]
	run valid_ipv6 "1:2:3:4:5:6:7:8:9"
	[ "$status" -ne 0 ]
	run valid_ipv6 "::1::2"
	[ "$status" -ne 0 ]
	run valid_ipv6 ""
	[ "$status" -ne 0 ]
	run valid_ipv6 "gggg::1"
	[ "$status" -ne 0 ]
}

@test "valid_ipv4_cidr accepts and rejects correctly" {
	run valid_ipv4_cidr "10.0.0.0/24"; [ "$status" -eq 0 ]
	run valid_ipv4_cidr "10.0.0.0/33"; [ "$status" -ne 0 ]
	run valid_ipv4_cidr "10.0.0.0"; [ "$status" -ne 0 ]
	run valid_ipv4_cidr "10.0.0.0/-1"; [ "$status" -ne 0 ]
}

@test "valid_ipv6_cidr accepts and rejects correctly" {
	run valid_ipv6_cidr "fd00::/64"; [ "$status" -eq 0 ]
	run valid_ipv6_cidr "fd00::/129"; [ "$status" -ne 0 ]
	run valid_ipv6_cidr "fd00::"; [ "$status" -ne 0 ]
}

@test "valid_port accepts 1-65535 and rejects out of range" {
	run valid_port "51820"; [ "$status" -eq 0 ]
	run valid_port "1"; [ "$status" -eq 0 ]
	run valid_port "65535"; [ "$status" -eq 0 ]
	run valid_port "0"; [ "$status" -ne 0 ]
	run valid_port "65536"; [ "$status" -ne 0 ]
	run valid_port "abc"; [ "$status" -ne 0 ]
	run valid_port "-1"; [ "$status" -ne 0 ]
	run valid_port "80; rm -rf /"; [ "$status" -ne 0 ]
}

@test "valid_peer_name accepts sane names and rejects hostile input" {
	run valid_peer_name "alice"; [ "$status" -eq 0 ]
	run valid_peer_name "bob-2"; [ "$status" -eq 0 ]
	run valid_peer_name "phone_1"; [ "$status" -eq 0 ]
	run valid_peer_name "-leadingdash"; [ "$status" -ne 0 ]
	run valid_peer_name ""; [ "$status" -ne 0 ]
	run valid_peer_name "../../etc/passwd"; [ "$status" -ne 0 ]
	run valid_peer_name "name with spaces"; [ "$status" -ne 0 ]
	run valid_peer_name "\$(rm -rf /)"; [ "$status" -ne 0 ]
	run valid_peer_name "this-name-is-definitely-way-too-long-to-be-valid"; [ "$status" -ne 0 ]
}

@test "valid_hostname accepts FQDNs and rejects garbage" {
	run valid_hostname "vpn.example.com"; [ "$status" -eq 0 ]
	run valid_hostname "localhost"; [ "$status" -eq 0 ]
	run valid_hostname "-bad.example.com"; [ "$status" -ne 0 ]
	run valid_hostname "bad_host!.com"; [ "$status" -ne 0 ]
}

@test "valid_endpoint_host accepts ipv4, ipv6, hostname" {
	run valid_endpoint_host "203.0.113.5"; [ "$status" -eq 0 ]
	run valid_endpoint_host "vpn.example.com"; [ "$status" -eq 0 ]
	run valid_endpoint_host "[2001:db8::1]"; [ "$status" -eq 0 ]
	run valid_endpoint_host ""; [ "$status" -ne 0 ]
	run valid_endpoint_host "; ls"; [ "$status" -ne 0 ]
}

@test "valid_base64_key accepts wg-style keys and rejects garbage" {
	local key
	key="$(head -c 32 /dev/urandom | base64)"
	run valid_base64_key "$key"; [ "$status" -eq 0 ]
	run valid_base64_key "short"; [ "$status" -ne 0 ]
	run valid_base64_key ""; [ "$status" -ne 0 ]
}

@test "valid_mtu range checks" {
	run valid_mtu "1420"; [ "$status" -eq 0 ]
	run valid_mtu "575"; [ "$status" -ne 0 ]
	run valid_mtu "9001"; [ "$status" -ne 0 ]
}

@test "valid_keepalive range checks" {
	run valid_keepalive "0"; [ "$status" -eq 0 ]
	run valid_keepalive "25"; [ "$status" -eq 0 ]
	run valid_keepalive "-1"; [ "$status" -ne 0 ]
	run valid_keepalive "3601"; [ "$status" -ne 0 ]
}

@test "cidrs_overlap_ipv4 detects overlap and non-overlap" {
	run cidrs_overlap_ipv4 "10.0.0.0/24" "10.0.0.128/25"
	[ "$status" -eq 0 ]
	run cidrs_overlap_ipv4 "10.0.0.0/24" "10.0.1.0/24"
	[ "$status" -ne 0 ]
}

@test "ipv4_in_cidr works" {
	run ipv4_in_cidr "10.0.0.5" "10.0.0.0/24"
	[ "$status" -eq 0 ]
	run ipv4_in_cidr "10.0.1.5" "10.0.0.0/24"
	[ "$status" -ne 0 ]
}

@test "ipv4_to_int and int_to_ipv4 round-trip" {
	local i
	i="$(ipv4_to_int "192.168.1.10")"
	run int_to_ipv4 "$i"
	[ "$status" -eq 0 ]
	[ "$output" = "192.168.1.10" ]
}
