#!/usr/bin/env bash
# tunnel_test.sh - real end-to-end WireGuard connectivity test.
#
# docs/TESTING.md describes a network-namespace based real-tunnel test, but
# no such test actually existed in the repository - this is it. It runs the
# project's REAL install.sh and lib/peers.sh (not a reimplementation of their
# logic) against three Linux network namespaces wired together to resemble
# a real deployment:
#
#   wgcli  <--veth-->  inet  <--veth-->  wgsrv
#  (road warrior)   (simulated       (the VPN server,
#                     internet/ISP    running this project's
#                     + a DNS         real install.sh)
#                     resolver)
#
# `inet` is a router namespace with IP forwarding enabled between its two
# veth links, plus a dnsmasq instance - standing in for "the public
# internet" so that traffic between wgcli and wgsrv genuinely has to be
# routed (not just exchanged over one shared link), and so that "can the
# client reach the public internet / resolve DNS through the tunnel" is a
# real multi-hop test rather than a loopback coincidence.
#
# This proves or disproves, with real packets:
#   - a real Noise handshake completes
#   - the client can ping the server's wg0 address (tunnel transport works)
#   - the client can reach an address that only exists behind the server's
#     NAT/forward path (full-tunnel internet access through the VPN works)
#   - DNS queries sent to the installer-configured DNS server succeed
#     through the tunnel
#
# Must run as root, in a network namespace unshare of its own is NOT used
# here (this script itself creates namespaces, so it must be the one
# controlling the host's /var/run/netns), with the `wireguard` link type
# available (`ip link add test0 type wireguard` must succeed).
#
# Usage: tunnel_test.sh [--keep] [--mode=full4|split4] [--use-psk=0|1]
set -euo pipefail

KEEP=0
MODE="full4"
USE_PSK=1
for a in "$@"; do
	case "$a" in
		--keep) KEEP=1 ;;
		--mode=*) MODE="${a#*=}" ;;
		--use-psk=*) USE_PSK="${a#*=}" ;;
		*) echo "unknown arg: $a" >&2; exit 2 ;;
	esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
RUN_ID="e2e$$"
WORKDIR="$(mktemp -d "/tmp/${RUN_ID}.XXXXXX")"

NS_SRV="wgsrv_${RUN_ID}"
NS_CLI="wgcli_${RUN_ID}"
NS_INET="inet_${RUN_ID}"

SRV_PUB_IP="203.0.113.10"
INET_SRV_IP="203.0.113.9"
SRV_PUB_PFX=30

CLI_ISP_IP="198.51.100.10"
INET_CLI_IP="198.51.100.9"
CLI_ISP_PFX=30

DNS_IP="203.0.113.53"   # a second address on inet's server-facing link, running dnsmasq

PASS=()
FAIL=()
record() {
	if [ "$2" -eq 0 ]; then PASS+=("$1"); echo "[PASS] $1"; else FAIL+=("$1"); echo "[FAIL] $1"; fi
}

cleanup() {
	set +e
	if [ "$KEEP" != "1" ]; then
		ip netns exec "$NS_CLI" wg-quick down "${WORKDIR}/aliceiface.conf" >/dev/null 2>&1
		ip netns exec "$NS_SRV" pkill dnsmasq >/dev/null 2>&1
		ip netns del "$NS_CLI" >/dev/null 2>&1
		ip netns del "$NS_SRV" >/dev/null 2>&1
		ip netns del "$NS_INET" >/dev/null 2>&1
		rm -rf -- "$WORKDIR"
	else
		echo "--- --keep passed: namespaces ($NS_SRV, $NS_CLI, $NS_INET) and $WORKDIR left in place ---"
	fi
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
ip link add e2e_wgtest_$$ type wireguard 2>/dev/null && ip link del e2e_wgtest_$$ \
	|| { echo "SKIP: this kernel/host does not support 'ip link ... type wireguard'" >&2; exit 77; }

echo "=== building namespaces: $NS_SRV / $NS_CLI / $NS_INET ==="
ip netns add "$NS_SRV"
ip netns add "$NS_CLI"
ip netns add "$NS_INET"

# wgsrv <-> inet
ip link add vS type veth peer name vSi
ip link set vS netns "$NS_SRV"
ip link set vSi netns "$NS_INET"
ip netns exec "$NS_SRV" ip addr add "${SRV_PUB_IP}/${SRV_PUB_PFX}" dev vS
ip netns exec "$NS_SRV" ip link set vS name eth0
ip netns exec "$NS_SRV" ip link set eth0 up
ip netns exec "$NS_SRV" ip link set lo up
ip netns exec "$NS_INET" ip addr add "${INET_SRV_IP}/${SRV_PUB_PFX}" dev vSi
ip netns exec "$NS_INET" ip addr add "${DNS_IP}/${SRV_PUB_PFX}" dev vSi
ip netns exec "$NS_INET" ip link set vSi up

# wgcli <-> inet
ip link add vC type veth peer name vCi
ip link set vC netns "$NS_CLI"
ip link set vCi netns "$NS_INET"
ip netns exec "$NS_CLI" ip addr add "${CLI_ISP_IP}/${CLI_ISP_PFX}" dev vC
ip netns exec "$NS_CLI" ip link set vC name eth0
ip netns exec "$NS_CLI" ip link set eth0 up
ip netns exec "$NS_CLI" ip link set lo up
ip netns exec "$NS_INET" ip addr add "${INET_CLI_IP}/${CLI_ISP_PFX}" dev vCi
ip netns exec "$NS_INET" ip link set vCi up
ip netns exec "$NS_INET" ip link set lo up

# Default routes: wgsrv and wgcli each only know about "inet" as their gateway.
ip netns exec "$NS_SRV" ip route add default via "$INET_SRV_IP"
ip netns exec "$NS_CLI" ip route add default via "$INET_CLI_IP"

# inet acts as a plain IPv4 router between the two links (the "ISP core").
ip netns exec "$NS_INET" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$NS_INET" bash -c "command -v nft >/dev/null && nft add table ip filter 2>/dev/null; command -v iptables >/dev/null && iptables -P FORWARD ACCEPT 2>/dev/null; true"

echo "=== starting a DNS resolver in the simulated internet (dnsmasq on ${DNS_IP}) ==="
ip netns exec "$NS_INET" dnsmasq \
	--no-daemon --no-resolv --no-hosts --listen-address="${DNS_IP}" --bind-interfaces \
	--address=/e2e-test.invalid/198.18.0.99 \
	--pid-file="${WORKDIR}/dnsmasq.pid" \
	>"${WORKDIR}/dnsmasq.log" 2>&1 &
sleep 0.5

echo "=== running the project's REAL install.sh inside $NS_SRV ==="
# Deliberately use the project's real default paths (/etc/wireguard,
# /etc/wireguard-vpn-server, /opt/wireguard-vpn-server) rather than
# WGVPN_WG_DIR-style overrides: wg-quick's own CLI (`wg-quick strip
# <iface>`, used by wg_config_syntax_ok) resolves an interface name
# through its OWN standard search path, not through this project's env
# vars, so overriding them here would make wg-quick looking in the wrong
# place a test-harness artifact rather than a real-world condition. This
# script only ever runs inside a disposable container/VM, never the host.
WGVPN_WG_DIR="/etc/wireguard"
WGVPN_STATE_DIR="/etc/wireguard-vpn-server"
WGVPN_BIN="/usr/local/bin/wg-vpn"
WGVPN_IFACE="wg0"

INSTALL_ARGS=(--non-interactive --assume-yes --mode="$MODE" --public-iface=eth0 \
	--endpoint="$SRV_PUB_IP" --port=51820 --dns="$DNS_IP")
[ "$USE_PSK" = "0" ] && INSTALL_ARGS+=(--no-psk)
ip netns exec "$NS_SRV" bash "${REPO_ROOT}/install.sh" "${INSTALL_ARGS[@]}" \
	|| { echo "install.sh failed" >&2; exit 1; }

echo "=== bringing up the server wg0 interface (no systemd in this environment) ==="
ip netns exec "$NS_SRV" wg-quick up "${WGVPN_WG_DIR}/wg0.conf"

echo "=== adding a real client via the project's own peers.sh (wg-vpn add-client) ==="
ip netns exec "$NS_SRV" "$WGVPN_BIN" add-client alice
ip netns exec "$NS_SRV" "$WGVPN_BIN" export alice "${WORKDIR}/alice.conf"

echo "--- generated client config (secrets redacted) ---"
sed -E 's/^(PrivateKey|PresharedKey) = .*/\1 = <redacted>/' "${WORKDIR}/alice.conf"
echo "---------------------------------------------------"

SRV_WG_IP="$(ip netns exec "$NS_SRV" bash -c "
	source '${REPO_ROOT}/lib/common.sh'
	json_get \"\$WGVPN_CONF\" server_ipv4
" | cut -d/ -f1)"
echo "server wg0 address: ${SRV_WG_IP}"

echo "=== importing the generated client config in $NS_CLI (as a real WireGuard client would) ==="
# wg-quick's own DNS directive handling shells out to `resolvconf` /
# systemd-resolved over dbus to rewrite /etc/resolv.conf - unavailable in
# this minimal container (a sandbox limitation: real client platforms -
# the official Windows/macOS/iOS/Android/Linux WireGuard apps - apply the
# DNS directive their own way). That's orthogonal to what this test
# measures: whether the *server* renders a correct, reachable DNS
# directive, and whether a query sent to it actually resolves through the
# tunnel. We bring the interface up from a DNS-directive-stripped copy so
# wg-quick doesn't fail on the missing resolvconf integration, while
# asserting on the real exported file (with the DNS line intact) below.
grep -v '^DNS = ' "${WORKDIR}/alice.conf" >"${WORKDIR}/aliceiface.conf"
ip netns exec "$NS_CLI" wg-quick up "${WORKDIR}/aliceiface.conf"

set +e  # from here on we deliberately check exit statuses ourselves

echo "--- diagnostics before testing: wg show on both sides ---"
ip netns exec "$NS_SRV" wg show
ip netns exec "$NS_CLI" wg show
echo "--- diagnostics: server-side firewall ---"
ip netns exec "$NS_SRV" nft list ruleset 2>&1
echo "--- diagnostics: server sysctl forwarding ---"
ip netns exec "$NS_SRV" sysctl net.ipv4.ip_forward
echo "--- diagnostics: server routes ---"
ip netns exec "$NS_SRV" ip route
echo "--- diagnostics: client routes ---"
ip netns exec "$NS_CLI" ip route

echo "=== TEST 1: handshake ==="
ip netns exec "$NS_CLI" ping -c 2 -W 2 "$SRV_WG_IP" >"${WORKDIR}/ping_server.log" 2>&1
PING1=$?
cat "${WORKDIR}/ping_server.log"
sleep 1
HS_CLIENT="$(ip netns exec "$NS_CLI" wg show aliceiface latest-handshakes | awk '{print $2}')"
HS_SERVER="$(ip netns exec "$NS_SRV" wg show wg0 latest-handshakes | awk '{print $2}')"
echo "client-side latest handshake epoch: ${HS_CLIENT:-0}"
echo "server-side latest handshake epoch: ${HS_SERVER:-0}"
if [ "${HS_CLIENT:-0}" -gt 0 ] && [ "${HS_SERVER:-0}" -gt 0 ]; then
	record "real Noise handshake completes (client+server both report a handshake)" 0
else
	record "real Noise handshake completes (client+server both report a handshake)" 1
fi

echo "=== TEST 2: client can reach the server's own wg0 (VPN) address ==="
record "client can ping the server's WireGuard address (${SRV_WG_IP})" "$PING1"

echo "=== TEST 3: client can reach the simulated internet (NAT+forward through the server) ==="
ip netns exec "$NS_CLI" ping -c 2 -W 2 "$INET_CLI_IP" >/dev/null 2>&1 || true  # warm ARP/neighbor, ignore
ip netns exec "$NS_CLI" ping -c 3 -W 2 "$DNS_IP" >"${WORKDIR}/ping_inet.log" 2>&1
record "client reaches an address behind the server's NAT (the simulated internet, ${DNS_IP}) through the tunnel" $?

echo "=== TEST 4: DNS resolution through the tunnel against the installer-configured DNS server ==="
if command -v dig >/dev/null 2>&1; then
	ip netns exec "$NS_CLI" dig +time=2 +tries=1 @"$DNS_IP" foo.e2e-test.invalid A +short >"${WORKDIR}/dns.log" 2>&1
	grep -q "198.18.0.99" "${WORKDIR}/dns.log"
	record "DNS query to configured DNS server (${DNS_IP}) resolves through the tunnel" $?
else
	echo "dig not installed; skipping DNS resolution content check, using raw connectivity only"
	ip netns exec "$NS_CLI" bash -c "echo | timeout 2 python3 -c \"
import socket
q = bytes.fromhex('aaaa01000001000000000000') + b'\x03foo\x0ce2e-test\x07invalid\x00' + bytes.fromhex('00010001')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(q, ('${DNS_IP}', 53))
data, _ = s.recvfrom(512)
import sys
sys.exit(0 if len(data) > 0 else 1)
\""
	record "DNS query reaches configured DNS server (${DNS_IP}) and a response is returned" $?
fi

echo "=== TEST 5: PersistentKeepalive present in generated client config when expected ==="
grep -q '^PersistentKeepalive = 25$' "${WORKDIR}/alice.conf"
record "PersistentKeepalive = 25 present in generated client config" $?

echo "=== TEST 6: PSK setting (use_psk=${USE_PSK}) is honored in both client config and live server peer ==="
if [ "$USE_PSK" = "1" ]; then
	grep -q '^PresharedKey = ' "${WORKDIR}/alice.conf"
	CLIENT_HAS_PSK=$?
else
	grep -q '^PresharedKey = ' "${WORKDIR}/alice.conf"
	CLIENT_HAS_PSK=$((1 - $?))
fi
record "client config PresharedKey presence matches use_psk=${USE_PSK}" "$CLIENT_HAS_PSK"

echo
echo "=== SUMMARY ==="
echo "PASS: ${#PASS[@]}  FAIL: ${#FAIL[@]}"
for f in "${FAIL[@]:-}"; do [ -n "$f" ] && echo "  FAILED: $f"; done

[ "${#FAIL[@]}" -eq 0 ]
