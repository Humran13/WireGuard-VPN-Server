#!/usr/bin/env bash
# firewall_test.sh - regression coverage for the FORWARD-chain compatibility
# fix (restrictive host firewalls: Docker, OpenVPN, admin-defined DROP
# policies). Each test runs in its own, fresh network namespace so it
# exercises the real `iptables`/`nft` tools against an isolated set of
# netfilter tables - never the host's/runner's real firewall.
#
# Root required. Usage: sudo bash tests/e2e/firewall_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
PASS=() FAIL=()
record() { if [ "$2" -eq 0 ]; then PASS+=("$1"); echo "[PASS] $1"; else FAIL+=("$1"); echo "[FAIL] $1"; fi; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
command_exists_() { command -v "$1" >/dev/null 2>&1; }
command_exists_ iptables || { echo "SKIP: iptables not found" >&2; exit 77; }

# in_ns <ns> <cmd...>: run inside the given (already-created) namespace.
in_ns() { ip netns exec "$1" "${@:2}"; }

setup_ns() {
	local ns="$1"
	ip netns add "$ns"
	in_ns "$ns" ip link set lo up
	in_ns "$ns" ip link add wgtest0 type dummy 2>/dev/null
	in_ns "$ns" ip link set wgtest0 up
	in_ns "$ns" ip link add ethtest0 type dummy 2>/dev/null
	in_ns "$ns" ip link set ethtest0 up
}

teardown_ns() {
	ip netns del "$1" >/dev/null 2>&1 || true
}

# run_fw_apply <ns> <state_dir> [extra env...]: sources the project's
# firewall lib inside the namespace and calls fw_apply with test interfaces.
run_fw_apply() {
	local ns="$1" state_dir="$2"
	in_ns "$ns" env WGVPN_STATE_DIR="$state_dir" WGVPN_IFACE="wgtest0" bash -c "
		source '${REPO_ROOT}/lib/common.sh'
		source '${REPO_ROOT}/lib/network.sh'
		source '${REPO_ROOT}/lib/firewall.sh'
		fw_apply 51820 nat ethtest0 10.66.66.0/24 '' 1
	"
}

run_fw_remove() {
	local ns="$1" state_dir="$2"
	in_ns "$ns" env WGVPN_STATE_DIR="$state_dir" WGVPN_IFACE="wgtest0" bash -c "
		source '${REPO_ROOT}/lib/common.sh'
		source '${REPO_ROOT}/lib/network.sh'
		source '${REPO_ROOT}/lib/firewall.sh'
		fw_remove
	"
}

run_fw_status() {
	local ns="$1" state_dir="$2"
	in_ns "$ns" env WGVPN_STATE_DIR="$state_dir" WGVPN_IFACE="wgtest0" bash -c "
		source '${REPO_ROOT}/lib/common.sh'
		source '${REPO_ROOT}/lib/network.sh'
		source '${REPO_ROOT}/lib/firewall.sh'
		fw_status_report
	"
}

compat_rules_present() {
	local ns="$1"
	in_ns "$ns" iptables -C FORWARD -i wgtest0 -o ethtest0 -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null \
		&& in_ns "$ns" iptables -C FORWARD -i ethtest0 -o wgtest0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null
}

count_compat_accept_rules() {
	local ns="$1"
	in_ns "$ns" iptables -S FORWARD 2>/dev/null | grep -c -- "wireguard-vpn-server"
}

# --- Test A: clean/fresh server (no conflicting DROP policy) ---------------
NS=fwtest_a; setup_ns "$NS"; SD="/tmp/${NS}.state"
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
compat_rules_present "$NS"
record "A: fresh server (no DROP policy) gets compat rules installed cleanly" $?
teardown_ns "$NS"

# --- Test B: existing FORWARD DROP policy -----------------------------------
NS=fwtest_b; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -P FORWARD DROP
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
compat_rules_present "$NS"
record "B: FORWARD policy DROP - compat rules installed" $?
# must be at the top (position 1) so they're evaluated before any later DROP
pos="$(in_ns "$NS" iptables -L FORWARD --line-numbers 2>/dev/null | awk '/wireguard-vpn-server/{print $1; exit}')"
[ "$pos" = "1" ]
record "B: compat rule is at the top of the FORWARD chain" $?
teardown_ns "$NS"

# --- Test C: Docker-like environment (DOCKER-USER/DOCKER-FORWARD, DROP) ----
NS=fwtest_c; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -N DOCKER-USER
in_ns "$NS" iptables -N DOCKER-FORWARD
in_ns "$NS" iptables -A DOCKER-USER -j RETURN
in_ns "$NS" iptables -A DOCKER-FORWARD -j RETURN
in_ns "$NS" iptables -A FORWARD -j DOCKER-USER
in_ns "$NS" iptables -A FORWARD -j DOCKER-FORWARD
in_ns "$NS" iptables -P FORWARD DROP
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
compat_rules_present "$NS"
record "C: Docker-like DOCKER-USER/DOCKER-FORWARD + DROP - compat rules installed" $?
in_ns "$NS" iptables -C FORWARD -j DOCKER-USER 2>/dev/null
record "C: Docker's DOCKER-USER jump rule untouched" $?
in_ns "$NS" iptables -C FORWARD -j DOCKER-FORWARD 2>/dev/null
record "C: Docker's DOCKER-FORWARD jump rule untouched" $?
teardown_ns "$NS"

# --- Test D: OpenVPN coexistence --------------------------------------------
NS=fwtest_d; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" ip link add ovpntest0 type dummy 2>/dev/null
in_ns "$NS" ip link set ovpntest0 up
in_ns "$NS" iptables -A FORWARD -i ovpntest0 -o ethtest0 -j ACCEPT
in_ns "$NS" iptables -A FORWARD -i ethtest0 -o ovpntest0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
in_ns "$NS" iptables -P FORWARD DROP
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
compat_rules_present "$NS"
record "D: compat rules installed alongside existing OpenVPN rules" $?
in_ns "$NS" iptables -C FORWARD -i ovpntest0 -o ethtest0 -j ACCEPT 2>/dev/null
record "D: OpenVPN's ovpn->eth ACCEPT rule untouched" $?
in_ns "$NS" iptables -C FORWARD -i ethtest0 -o ovpntest0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
record "D: OpenVPN's eth->ovpn RELATED,ESTABLISHED rule untouched" $?
teardown_ns "$NS"

# --- Test E: idempotency ----------------------------------------------------
NS=fwtest_e; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -P FORWARD DROP
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
run_fw_apply "$NS" "$SD" >>/tmp/${NS}.log 2>&1
run_fw_apply "$NS" "$SD" >>/tmp/${NS}.log 2>&1
count="$(count_compat_accept_rules "$NS")"
[ "$count" -eq 2 ]
record "E: running fw_apply three times leaves exactly 2 compat rules (no duplicates)" $?
teardown_ns "$NS"

# --- Test F: cleanup removes only project-owned rules -----------------------
NS=fwtest_f; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -A FORWARD -i ovpntest0 -o ethtest0 -j ACCEPT 2>/dev/null || true
in_ns "$NS" ip link add ovpntest0 type dummy 2>/dev/null
in_ns "$NS" iptables -A FORWARD -i ovpntest0 -o ethtest0 -j ACCEPT
in_ns "$NS" iptables -P FORWARD DROP
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
run_fw_remove "$NS" "$SD" >>/tmp/${NS}.log 2>&1
compat_rules_present "$NS"
record "F: cleanup removes the project's own compat rules" $(( 1 - $? ))
in_ns "$NS" iptables -C FORWARD -i ovpntest0 -o ethtest0 -j ACCEPT 2>/dev/null
record "F: cleanup leaves the foreign (OpenVPN-like) rule untouched" $?
run_fw_remove "$NS" "$SD" >>/tmp/${NS}.log 2>&1
record "F: a second cleanup does not fail when rules are already gone" $?
teardown_ns "$NS"

# --- Test G: diagnostics signals --------------------------------------------
NS=fwtest_g; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -P FORWARD DROP
mkdir -p "$SD"
report="$(run_fw_apply "$NS" "$SD" 2>&1; run_fw_status "$NS" "$SD" 2>&1)"
[[ "$report" == *"host_forward_policy=DROP"* ]] && [[ "$report" == *"compat_forward_rule=present"* ]]
record "G: diagnostics report host_forward_policy=DROP + compat_forward_rule=present once fixed" $?
teardown_ns "$NS"

NS=fwtest_g2; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" iptables -P FORWARD DROP
mkdir -p "$SD"
report="$(run_fw_status "$NS" "$SD" 2>&1)"
[[ "$report" == *"host_forward_policy=DROP"* ]] && [[ "$report" == *"compat_forward_rule=absent"* ]]
record "G: diagnostics report compat_forward_rule=absent before any fix is applied" $?
teardown_ns "$NS"

# --- Test H: public interface handling --------------------------------------
NS=fwtest_h; setup_ns "$NS"; SD="/tmp/${NS}.state"
in_ns "$NS" ip link add ethtest1 type dummy 2>/dev/null
in_ns "$NS" ip link set ethtest1 up
in_ns "$NS" iptables -P FORWARD DROP
in_ns "$NS" env WGVPN_STATE_DIR="$SD" WGVPN_IFACE="wgtest0" bash -c "
	source '${REPO_ROOT}/lib/common.sh'
	source '${REPO_ROOT}/lib/network.sh'
	source '${REPO_ROOT}/lib/firewall.sh'
	fw_apply 51820 nat ethtest1 10.66.66.0/24 '' 1
" >/tmp/${NS}.log 2>&1
in_ns "$NS" iptables -C FORWARD -i wgtest0 -o ethtest1 -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null
record "H: compat rule uses the configured public interface (ethtest1), not a hardcoded eth0" $?
in_ns "$NS" iptables -C FORWARD -i wgtest0 -o ethtest0 -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null
record "H: no stray rule for a different/unconfigured interface (ethtest0)" $(( 1 - $? ))
# now simulate the public interface changing (ethtest1 -> ethtest0) via repair
in_ns "$NS" env WGVPN_STATE_DIR="$SD" WGVPN_IFACE="wgtest0" bash -c "
	source '${REPO_ROOT}/lib/common.sh'
	source '${REPO_ROOT}/lib/network.sh'
	source '${REPO_ROOT}/lib/firewall.sh'
	fw_apply 51820 nat ethtest0 10.66.66.0/24 '' 1
" >>/tmp/${NS}.log 2>&1
in_ns "$NS" iptables -C FORWARD -i wgtest0 -o ethtest0 -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null
record "H: after an interface change, the new interface's compat rule is installed" $?
in_ns "$NS" iptables -C FORWARD -i wgtest0 -o ethtest1 -m comment --comment wireguard-vpn-server -j ACCEPT 2>/dev/null
record "H: after an interface change, the OLD interface's stale compat rule is removed" $(( 1 - $? ))
teardown_ns "$NS"

# --- Test I: NAT rule correctness/idempotency --------------------------------
NS=fwtest_i; setup_ns "$NS"; SD="/tmp/${NS}.state"
run_fw_apply "$NS" "$SD" >/tmp/${NS}.log 2>&1
run_fw_apply "$NS" "$SD" >>/tmp/${NS}.log 2>&1
backend="$(run_fw_status "$NS" "$SD" 2>/dev/null | awk -F= '/^backend=/{print $2}')"
if [ "$backend" = "nftables" ]; then
	count="$(in_ns "$NS" nft list table ip wgvpnserver_nat 2>/dev/null | grep -c 'masquerade')"
else
	count="$(in_ns "$NS" iptables -t nat -S POSTROUTING 2>/dev/null | grep -c 'MASQUERADE')"
fi
[ "$count" -eq 1 ]
record "I: exactly one NAT/masquerade rule for the VPN subnet after repeated apply (backend=${backend})" $?
teardown_ns "$NS"

echo
echo "=== SUMMARY ==="
echo "PASS: ${#PASS[@]}  FAIL: ${#FAIL[@]}"
for f in "${FAIL[@]:-}"; do [ -n "$f" ] && echo "  FAILED: $f"; done
[ "${#FAIL[@]}" -eq 0 ]
