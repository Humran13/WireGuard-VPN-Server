#!/usr/bin/env bash
# wireguard.sh - package install, key management, config rendering, service control
# shellcheck shell=bash

if [ -n "${WGVPN_WG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_WG_LOADED=1

# wg_install_packages: installs wireguard-tools (+ kernel module where needed)
# per Ubuntu release. Never silently swaps in an unrelated VPN implementation.
wg_install_packages() {
	local needed=()
	command_exists wg || needed+=("wg")
	command_exists wg-quick || needed+=("wg-quick")

	if [ "${#needed[@]}" -eq 0 ] && [ "$(os_kernel_wireguard_status)" != "missing" ]; then
		ok "wireguard-tools already installed."
		return 0
	fi

	info "Installing WireGuard (native kernel implementation) and wireguard-tools..."
	os_install_packages ca-certificates curl gnupg lsb-release qrencode iproute2 >/dev/null 2>&1 || true

	case "$OS_VERSION_ID" in
		18.04)
			# Bionic's default 4.15 kernel predates in-tree WireGuard support.
			# Try universe first (HWE kernels on updated 18.04 may already carry it),
			# fall back to the official WireGuard PPA + DKMS module.
			if apt-get install -y -qq wireguard wireguard-tools >/dev/null 2>&1; then
				ok "Installed wireguard from Ubuntu repositories."
			else
				info "wireguard package unavailable on this 18.04 kernel; adding official WireGuard PPA."
				os_install_packages software-properties-common
				add-apt-repository -y ppa:wireguard/wireguard >/dev/null 2>&1 \
					|| die "Failed to add WireGuard PPA on Ubuntu 18.04."
				apt-get update -qq
				os_install_packages "linux-headers-$(uname -r)" wireguard-dkms wireguard-tools \
					|| die "Failed to install WireGuard DKMS module on Ubuntu 18.04."
			fi
			;;
		*)
			os_install_packages wireguard wireguard-tools \
				|| die "Failed to install wireguard-tools via apt."
			;;
	esac

	command_exists wg || die "wg binary not found after installation."
	command_exists wg-quick || die "wg-quick not found after installation."
	ok "WireGuard tools installed."
}

# wg_genkey: prints a new private key
wg_genkey() { wg genkey; }

# wg_pubkey <privkey>: prints the derived public key
wg_pubkey() { wg pubkey <<<"$1"; }

# wg_genpsk: prints a new preshared key
wg_genpsk() { wg genpsk; }

# --- Server config rendering -------------------------------------------------

# wg_render_server_config: writes ${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf from
# ${WGVPN_CONF} state (server_private_key, wg_port, server_ipv4, server_ipv6,
# mtu) plus all enabled clients/site-peers. ${WGVPN_CONF} must already exist.
wg_render_server_config() {
	local conf="${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
	local privkey port ipv4 ipv6 mtu addr_line
	privkey="$(json_get "$WGVPN_CONF" server_private_key)"
	port="$(json_get "$WGVPN_CONF" wg_port)"
	ipv4="$(json_get "$WGVPN_CONF" server_ipv4)"
	ipv6="$(json_get "$WGVPN_CONF" server_ipv6)"
	mtu="$(json_get "$WGVPN_CONF" mtu)"

	addr_line="$ipv4"
	if [ -n "$ipv6" ]; then addr_line="${addr_line},${ipv6}"; fi

	{
		echo "# Managed by wireguard-vpn-server. Do not edit by hand; use 'wg-vpn'."
		echo "[Interface]"
		echo "PrivateKey = ${privkey}"
		echo "Address = ${addr_line}"
		echo "ListenPort = ${port}"
		if [ -n "$mtu" ]; then echo "MTU = ${mtu}"; fi
		echo "PostUp = ${WGVPN_STATE_DIR}/hooks/postup.sh"
		echo "PostDown = ${WGVPN_STATE_DIR}/hooks/postdown.sh"
		echo

		local f
		if [ -d "$WGVPN_CLIENTS_DIR" ]; then
			for f in "$WGVPN_CLIENTS_DIR"/*.json; do
				[ -e "$f" ] || continue
				wg_peer_block_from_client_json "$f"
			done
		fi
		if [ -d "$WGVPN_PEERS_DIR" ]; then
			for f in "$WGVPN_PEERS_DIR"/*.json; do
				[ -e "$f" ] || continue
				wg_peer_block_from_site_json "$f"
			done
		fi
	} | atomic_write "$conf" 0600
}

# wg_peer_block_from_client_json <file>: emits a [Peer] stanza if client is enabled
wg_peer_block_from_client_json() {
	local f="$1"
	local enabled pubkey psk addr4 addr6
	enabled="$(json_get "$f" enabled)"
	[ "$enabled" = "true" ] || return 0
	pubkey="$(json_get "$f" public_key)"
	psk="$(json_get "$f" preshared_key)"
	addr4="$(json_get "$f" vpn_ipv4)"
	addr6="$(json_get "$f" vpn_ipv6)"
	local allowed="${addr4}/32"
	if [ -n "$addr6" ]; then allowed="${allowed},${addr6}/128"; fi
	echo "[Peer]"
	echo "# Client: $(json_get "$f" name)"
	echo "PublicKey = ${pubkey}"
	if [ -n "$psk" ]; then echo "PresharedKey = ${psk}"; fi
	echo "AllowedIPs = ${allowed}"
	echo
}

# wg_peer_block_from_site_json <file>: emits a [Peer] stanza for a site-to-site peer
wg_peer_block_from_site_json() {
	local f="$1"
	local enabled pubkey psk routes endpoint keepalive
	enabled="$(json_get "$f" enabled)"
	[ "$enabled" = "true" ] || return 0
	pubkey="$(json_get "$f" public_key)"
	psk="$(json_get "$f" preshared_key)"
	routes="$(json_get "$f" allowed_ips)"
	endpoint="$(json_get "$f" endpoint)"
	keepalive="$(json_get "$f" keepalive)"
	echo "[Peer]"
	echo "# Site-to-site: $(json_get "$f" name)"
	echo "PublicKey = ${pubkey}"
	if [ -n "$psk" ]; then echo "PresharedKey = ${psk}"; fi
	echo "AllowedIPs = ${routes}"
	if [ -n "$endpoint" ]; then echo "Endpoint = ${endpoint}"; fi
	if [ -n "$keepalive" ] && [ "$keepalive" != "0" ]; then echo "PersistentKeepalive = ${keepalive}"; fi
	echo
}

# wg_systemd_available: 0 if a real systemd instance (PID 1) is running.
# Container/CI environments often lack this; the manager degrades gracefully
# instead of hard-failing when it's absent.
wg_systemd_available() {
	[ -d /run/systemd/system ]
}

wg_service_enable_start() {
	if ! wg_systemd_available; then
		warn "systemd is not running in this environment; skipping service enable/start."
		warn "On a real Ubuntu server this step brings the WireGuard interface up automatically."
		return 0
	fi
	systemctl enable "wg-quick@${WGVPN_IFACE}" >/dev/null 2>&1
	systemctl restart "wg-quick@${WGVPN_IFACE}"
}

wg_service_stop() {
	wg_systemd_available || return 0
	systemctl disable "wg-quick@${WGVPN_IFACE}" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@${WGVPN_IFACE}" >/dev/null 2>&1 || true
}

wg_service_status() {
	if ! wg_systemd_available; then
		echo "unknown (no systemd)"
		return 0
	fi
	systemctl is-active "wg-quick@${WGVPN_IFACE}" 2>/dev/null || echo "inactive"
}

wg_service_restart() {
	if ! wg_systemd_available; then
		warn "systemd is not running in this environment; cannot restart the service."
		return 0
	fi
	systemctl restart "wg-quick@${WGVPN_IFACE}"
}

# wg_apply_peer_live: sync running interface without full restart (used by add/remove client)
wg_apply_peer_live() {
	if [ "$(wg_service_status)" = "active" ]; then
		wg syncconf "$WGVPN_IFACE" <(wg-quick strip "$WGVPN_IFACE") 2>/dev/null || wg_service_restart
	fi
}

# wg_revoke_peer_live <pubkey>: immediately removes a peer from the live interface
wg_revoke_peer_live() {
	local pubkey="$1"
	if [ "$(wg_service_status)" = "active" ]; then
		wg set "$WGVPN_IFACE" peer "$pubkey" remove 2>/dev/null || true
	fi
}

# wg_config_syntax_ok: 0 if wg-quick strip parses the conf without error
wg_config_syntax_ok() {
	wg-quick strip "$WGVPN_IFACE" >/dev/null 2>&1
}
