#!/usr/bin/env bash
# install.sh - WireGuard VPN Server Manager installer for Ubuntu 18.04+
#
#   curl -fsSL https://raw.githubusercontent.com/Humran13/WireGuard-VPN-Server/main/install.sh | sudo bash
#
# shellcheck shell=bash
set -euo pipefail

WGVPN_PREFIX="${WGVPN_PREFIX:-/opt/wireguard-vpn-server}"
WGVPN_STATE_DIR="${WGVPN_STATE_DIR:-/etc/wireguard-vpn-server}"
WGVPN_WG_DIR="${WGVPN_WG_DIR:-/etc/wireguard}"
WGVPN_BIN="${WGVPN_BIN:-/usr/local/bin/wg-vpn}"
WGVPN_IFACE="${WGVPN_IFACE:-wg0}"
WGVPN_CONF="${WGVPN_STATE_DIR}/config.json"
WGVPN_CLIENTS_DIR="${WGVPN_STATE_DIR}/clients"
WGVPN_PEERS_DIR="${WGVPN_STATE_DIR}/site-peers"
WGVPN_BACKUP_DIR="${WGVPN_STATE_DIR}/backups"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# --- Bootstrap: fetch the repo if running via curl | bash (no local lib/) ---
FETCHED_ROOT=""
if [ ! -f "${SCRIPT_DIR}/lib/common.sh" ]; then
	WGVPN_INSTALL_REPO_RAW="${WGVPN_GH_RAW:-https://raw.githubusercontent.com/Humran13/WireGuard-VPN-Server/main}"
	FETCHED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wgvpn-src.XXXXXXXX")"
	echo "[INFO]  Fetching WireGuard-VPN-Server sources..."
	mkdir -p "${FETCHED_ROOT}/lib" "${FETCHED_ROOT}/bin"
	for f in common os validate network wireguard routing firewall peers backup diagnostics update uninstall; do
		curl -fsSL "${WGVPN_INSTALL_REPO_RAW}/lib/${f}.sh" -o "${FETCHED_ROOT}/lib/${f}.sh" \
			|| { echo "[FAIL] Failed to download lib/${f}.sh" >&2; exit 1; }
	done
	curl -fsSL "${WGVPN_INSTALL_REPO_RAW}/bin/wg-vpn" -o "${FETCHED_ROOT}/bin/wg-vpn" \
		|| { echo "[FAIL] Failed to download bin/wg-vpn" >&2; exit 1; }
	curl -fsSL "${WGVPN_INSTALL_REPO_RAW}/VERSION" -o "${FETCHED_ROOT}/VERSION" \
		|| { echo "[FAIL] Failed to download VERSION" >&2; exit 1; }
	SCRIPT_DIR="$FETCHED_ROOT"
fi

cleanup_fetched() {
	if [ -n "$FETCHED_ROOT" ] && [ -d "$FETCHED_ROOT" ]; then rm -rf -- "$FETCHED_ROOT"; fi
}
trap cleanup_fetched EXIT

# shellcheck source=/dev/null
for f in common os validate network wireguard routing firewall peers backup diagnostics update uninstall; do
	source "${SCRIPT_DIR}/lib/${f}.sh"
done

INSTALL_FAILED_PHASE=""
install_rollback() {
	local ec=$?
	if [ "$ec" -ne 0 ] && [ -n "$INSTALL_FAILED_PHASE" ]; then
		err "Installation failed during phase: ${INSTALL_FAILED_PHASE}"
		err "See ${WGVPN_LOG_FILE} for details. No changes were made to an existing working configuration beyond what is logged."
	fi
}
trap install_rollback EXIT

phase() { INSTALL_FAILED_PHASE="$1"; info "$1"; }

# --- CLI options -------------------------------------------------------------
NONINTERACTIVE="${WGVPN_NONINTERACTIVE:-0}"
OPT_MODE="${WGVPN_OPT_MODE:-full4}"
OPT_IPV4_SUBNET="${WGVPN_OPT_IPV4_SUBNET:-}"
OPT_IPV6_SUBNET="${WGVPN_OPT_IPV6_SUBNET:-}"
OPT_PORT="${WGVPN_OPT_PORT:-51820}"
OPT_DNS="${WGVPN_OPT_DNS:-1.1.1.1}"
OPT_ENDPOINT="${WGVPN_OPT_ENDPOINT:-}"
OPT_FORWARD_MODE="${WGVPN_OPT_FORWARD_MODE:-nat}"
OPT_PUBLIC_IFACE="${WGVPN_OPT_PUBLIC_IFACE:-}"
OPT_MTU="${WGVPN_OPT_MTU:-1420}"
OPT_KEEPALIVE="${WGVPN_OPT_KEEPALIVE:-25}"
OPT_USE_PSK="${WGVPN_OPT_USE_PSK:-1}"
OPT_CLIENT_ISOLATION="${WGVPN_OPT_CLIENT_ISOLATION:-1}"
ACTION="install"

while [ $# -gt 0 ]; do
	case "$1" in
		--non-interactive) NONINTERACTIVE=1 ;;
		--assume-yes|-y) WGVPN_ASSUME_YES=1 ;;
		--mode=*) OPT_MODE="${1#*=}" ;;
		--ipv4-subnet=*) OPT_IPV4_SUBNET="${1#*=}" ;;
		--ipv6-subnet=*) OPT_IPV6_SUBNET="${1#*=}" ;;
		--port=*) OPT_PORT="${1#*=}" ;;
		--dns=*) OPT_DNS="${1#*=}" ;;
		--endpoint=*) OPT_ENDPOINT="${1#*=}" ;;
		--forward-mode=*) OPT_FORWARD_MODE="${1#*=}" ;;
		--public-iface=*) OPT_PUBLIC_IFACE="${1#*=}" ;;
		--mtu=*) OPT_MTU="${1#*=}" ;;
		--keepalive=*) OPT_KEEPALIVE="${1#*=}" ;;
		--no-psk) OPT_USE_PSK=0 ;;
		--allow-peer-to-peer) OPT_CLIENT_ISOLATION=0 ;;
		--uninstall) ACTION="uninstall" ;;
		--full) ACTION="uninstall-full" ;;
		--repair) ACTION="repair" ;;
		--update) ACTION="update" ;;
		-h|--help)
			cat <<EOF
WireGuard VPN Server Manager installer

Usage: install.sh [options]
  --non-interactive          Run without prompts (requires sane defaults or flags below)
  --assume-yes, -y           Assume yes on confirmations
  --mode=MODE                full4|full6|full-dual|split4|split6|split-dual (default: full4)
  --ipv4-subnet=CIDR         VPN IPv4 subnet (default: auto-selected)
  --ipv6-subnet=CIDR         VPN IPv6 subnet (only used with IPv6 modes)
  --port=PORT                WireGuard UDP port (default: 51820)
  --dns=DNS                  Client DNS server(s), comma-separated (default: 1.1.1.1)
  --endpoint=HOST             Public endpoint host/IP (default: auto-detected)
  --forward-mode=MODE        nat|routed (default: nat)
  --public-iface=IFACE       Public network interface (default: auto-detected)
  --mtu=MTU                  WireGuard MTU (default: 1420)
  --keepalive=SECONDS        Default PersistentKeepalive (default: 25, 0 disables)
  --no-psk                   Disable per-peer preshared keys (not recommended)
  --allow-peer-to-peer       Allow client-to-client traffic (default: isolated)
  --uninstall                Remove the program (keep WireGuard config)
  --full                     Combined with --uninstall: remove everything
  --repair                   Run repair on an existing installation
  --update                   Self-update an existing installation
  -h, --help                  Show this help
EOF
			exit 0
			;;
		*) die "Unknown option: $1 (see --help)" ;;
	esac
	shift
done
if [ "$NONINTERACTIVE" = "1" ]; then WGVPN_ASSUME_YES=1; fi

require_root "$@"

phase "Detecting operating system"
os_check_support

# --- Handle existing installation ------------------------------------------
already_installed=0
if [ -x "$WGVPN_BIN" ] && [ -f "$WGVPN_CONF" ]; then already_installed=1; fi

if [ "$already_installed" = "1" ] && [ "$ACTION" = "install" ]; then
	if [ "${WGVPN_UPDATE_MODE:-0}" = "1" ]; then
		info "Update mode: reinstalling program files in place, preserving keys/clients/settings."
	elif [ "$NONINTERACTIVE" = "1" ]; then
		info "Existing installation detected; non-interactive mode will repair in place."
		ACTION="repair"
	else
		echo
		echo "WireGuard-VPN-Server appears to already be installed."
		echo "1. Open manager (sudo wg-vpn)"
		echo "2. Repair installation"
		echo "3. Update to latest version"
		echo "4. Reinstall (keeps existing clients where possible)"
		echo "5. Cancel"
		read -r -p "Select an option [1-5]: " existing_choice
		case "$existing_choice" in
			1) exec "$WGVPN_BIN" ;;
			2) ACTION="repair" ;;
			3) ACTION="update" ;;
			4) ACTION="install" ;;
			*) info "Cancelled."; exit 0 ;;
		esac
	fi
fi

if [ "$ACTION" = "uninstall" ] || [ "$ACTION" = "uninstall-full" ]; then
	mode="program"
	if [ "$ACTION" = "uninstall-full" ]; then mode="full"; fi
	uninstall_run "$mode"
	exit 0
fi

if [ "$ACTION" = "update" ]; then
	mkdir -p "$WGVPN_STATE_DIR"
	update_run
	exit 0
fi

if [ "$ACTION" = "repair" ] && [ "$already_installed" = "1" ]; then
	phase "Repairing existing installation"
	"$WGVPN_BIN" repair
	exit 0
fi

# Self-update: refresh program files in place and reconfigure from the
# EXISTING state (server keys, clients, settings) - never rederive them from
# install-time flags/defaults, which would silently reset the server.
if [ "$already_installed" = "1" ] && [ "${WGVPN_UPDATE_MODE:-0}" = "1" ]; then
	phase "Updating program files"
	mkdir -p "${WGVPN_PREFIX}/lib" "${WGVPN_PREFIX}/bin"
	cp -f "${SCRIPT_DIR}/lib/"*.sh "${WGVPN_PREFIX}/lib/"
	cp -f "${SCRIPT_DIR}/bin/wg-vpn" "${WGVPN_PREFIX}/bin/wg-vpn"
	cp -f "${SCRIPT_DIR}/VERSION" "${WGVPN_PREFIX}/VERSION"
	chmod +x "${WGVPN_PREFIX}/bin/wg-vpn"
	ln -sf "${WGVPN_PREFIX}/bin/wg-vpn" "$WGVPN_BIN"
	chmod +x "$WGVPN_BIN"
	phase "Reapplying configuration with updated code"
	"$WGVPN_BIN" repair
	INSTALL_FAILED_PHASE=""
	ok "Update complete: program files refreshed; keys, clients, and settings preserved."
	exit 0
fi

# --- Interactive wizard -------------------------------------------------------
if [ "$NONINTERACTIVE" != "1" ]; then
	echo
	echo "WireGuard VPN Server Manager - Installation Wizard"
	echo "===================================================="

	echo
	echo "Connection / routing mode:"
	echo "  1) IPv4 full tunnel (recommended)"
	echo "  2) IPv6 full tunnel"
	echo "  3) IPv4 + IPv6 dual-stack full tunnel"
	echo "  4) IPv4 split tunnel"
	echo "  5) IPv6 split tunnel"
	echo "  6) IPv4 + IPv6 split tunnel"
	read -r -p "Select [1-6, default 1]: " mchoice
	case "${mchoice:-1}" in
		1) OPT_MODE="full4" ;;
		2) OPT_MODE="full6" ;;
		3) OPT_MODE="full-dual" ;;
		4) OPT_MODE="split4" ;;
		5) OPT_MODE="split6" ;;
		6) OPT_MODE="split-dual" ;;
		*) OPT_MODE="full4" ;;
	esac

	read -r -p "WireGuard UDP port [${OPT_PORT}]: " v; OPT_PORT="${v:-$OPT_PORT}"
	valid_port "$OPT_PORT" || die "Invalid port: $OPT_PORT"

	read -r -p "Client DNS (comma-separated, blank for none) [${OPT_DNS}]: " v; OPT_DNS="${v-$OPT_DNS}"

	echo
	echo "Forwarding mode:"
	echo "  1) NAT / Masquerade (typical road-warrior VPN)"
	echo "  2) Routed / No-NAT (requires upstream routes already configured)"
	read -r -p "Select [1-2, default 1]: " fchoice
	[ "${fchoice:-1}" = "2" ] && OPT_FORWARD_MODE="routed" || OPT_FORWARD_MODE="nat"

	confirm "Enable per-client preshared keys (recommended)?" y && OPT_USE_PSK=1 || OPT_USE_PSK=0
	confirm "Isolate clients from each other (block peer-to-peer traffic)?" y && OPT_CLIENT_ISOLATION=1 || OPT_CLIENT_ISOLATION=0
fi

# --- Validate / derive settings ----------------------------------------------
phase "Validating configuration"
valid_port "$OPT_PORT" || die "Invalid port: $OPT_PORT"
case "$OPT_MODE" in full4|full6|full-dual|split4|split6|split-dual) ;; *) die "Invalid mode: $OPT_MODE" ;; esac
case "$OPT_FORWARD_MODE" in nat|routed) ;; *) die "Invalid forward mode: $OPT_FORWARD_MODE" ;; esac
valid_mtu "$OPT_MTU" || die "Invalid MTU: $OPT_MTU"
valid_keepalive "$OPT_KEEPALIVE" || die "Invalid keepalive: $OPT_KEEPALIVE"

need_ipv6=0
if routing_mode_requires_ipv6 "$OPT_MODE"; then need_ipv6=1; fi
if [ "$OPT_MODE" = "full-dual" ] || [ "$OPT_MODE" = "split-dual" ]; then need_ipv6=1; fi

ipv6_available=0
if net_ipv6_available; then ipv6_available=1; fi

if [ "$need_ipv6" = "1" ] && [ "$ipv6_available" = "0" ]; then
	warn "IPv6 was selected but this server does not have working IPv6 connectivity."
	warn "Falling back to IPv4-only for full/split-dual selections."
	case "$OPT_MODE" in
		full6|full-dual) OPT_MODE="full4" ;;
		split6|split-dual) OPT_MODE="split4" ;;
	esac
	need_ipv6=0
fi

if [ -z "$OPT_PUBLIC_IFACE" ]; then OPT_PUBLIC_IFACE="$(net_default_iface)"; fi
[ -n "$OPT_PUBLIC_IFACE" ] || die "Could not determine the public network interface. Pass --public-iface=<iface>."

if [ -z "$OPT_IPV4_SUBNET" ]; then OPT_IPV4_SUBNET="$(net_suggest_ipv4_subnet)"; fi
valid_ipv4_cidr "$OPT_IPV4_SUBNET" || die "Invalid IPv4 subnet: $OPT_IPV4_SUBNET"

if [ "$need_ipv6" = "1" ] && [ -z "$OPT_IPV6_SUBNET" ]; then
	OPT_IPV6_SUBNET="fd$(openssl rand -hex 1 2>/dev/null || echo 42):$(openssl rand -hex 2 2>/dev/null || echo beef):$(openssl rand -hex 2 2>/dev/null || echo cafe)::/64"
fi

if [ -z "$OPT_ENDPOINT" ]; then
	if [ "$need_ipv6" = "1" ]; then
		OPT_ENDPOINT="$(net_public_ipv6 || true)"
	fi
	if [ -z "$OPT_ENDPOINT" ]; then OPT_ENDPOINT="$(net_public_ipv4 || true)"; fi
	if [ -z "$OPT_ENDPOINT" ]; then die "Could not auto-detect a public endpoint. Pass --endpoint=<ip-or-hostname>."; fi
	if [ "$NONINTERACTIVE" != "1" ]; then
		read -r -p "Detected public endpoint [${OPT_ENDPOINT}] (press Enter to accept, or type a different host/IP): " v
		OPT_ENDPOINT="${v:-$OPT_ENDPOINT}"
	fi
fi
valid_endpoint_host "$OPT_ENDPOINT" || die "Invalid endpoint: $OPT_ENDPOINT"

# --- Install packages ---------------------------------------------------------
phase "Installing packages"
os_install_packages jq curl openssl iproute2 qrencode ca-certificates >/dev/null 2>&1 || warn "Some optional packages failed to install."
command_exists jq || die "jq is required but failed to install."
wg_install_packages

# --- Server keys / initial state ---------------------------------------------
phase "Generating server keys and state"
mkdir -p "$WGVPN_STATE_DIR" "$WGVPN_CLIENTS_DIR" "$WGVPN_PEERS_DIR" "$WGVPN_BACKUP_DIR" "${WGVPN_STATE_DIR}/hooks"
chmod 700 "$WGVPN_STATE_DIR"
mkdir -p "$WGVPN_WG_DIR"
chmod 700 "$WGVPN_WG_DIR"

if [ -f "$WGVPN_CONF" ]; then
	SRV_PRIVKEY="$(json_get "$WGVPN_CONF" server_private_key)"
	info "Existing server keys found; preserving them (idempotent reinstall)."
fi
if [ -z "${SRV_PRIVKEY:-}" ]; then
	SRV_PRIVKEY="$(wg_genkey)"
fi
SRV_PUBKEY="$(wg_pubkey "$SRV_PRIVKEY")"

SRV_IPV4_ADDR="$(int_to_ipv4 $(( $(ipv4_to_int "${OPT_IPV4_SUBNET%/*}") + 1 )))/${OPT_IPV4_SUBNET#*/}"
SRV_IPV6_ADDR=""
if [ -n "$OPT_IPV6_SUBNET" ]; then
	SRV_IPV6_ADDR="${OPT_IPV6_SUBNET%::*}::1/${OPT_IPV6_SUBNET#*/}"
fi

jq -n \
	--arg wg_port "$OPT_PORT" \
	--arg ipv4_subnet "$OPT_IPV4_SUBNET" \
	--arg ipv6_subnet "${OPT_IPV6_SUBNET:-}" \
	--argjson ipv6_enabled "$([ "$need_ipv6" = "1" ] && echo true || echo false)" \
	--arg default_mode "$OPT_MODE" \
	--arg default_dns "$OPT_DNS" \
	--arg default_keepalive "$OPT_KEEPALIVE" \
	--arg endpoint "${OPT_ENDPOINT}:${OPT_PORT}" \
	--arg forward_mode "$OPT_FORWARD_MODE" \
	--arg public_iface "$OPT_PUBLIC_IFACE" \
	--arg mtu "$OPT_MTU" \
	--argjson use_psk "$([ "$OPT_USE_PSK" = "1" ] && echo true || echo false)" \
	--argjson client_isolation "$([ "$OPT_CLIENT_ISOLATION" = "1" ] && echo true || echo false)" \
	--arg server_private_key "$SRV_PRIVKEY" \
	--arg server_public_key "$SRV_PUBKEY" \
	--arg server_ipv4 "$SRV_IPV4_ADDR" \
	--arg server_ipv6 "$SRV_IPV6_ADDR" \
	--arg version "$WGVPN_VERSION" \
	'{wg_port:$wg_port, ipv4_subnet:$ipv4_subnet, ipv6_subnet:$ipv6_subnet, ipv6_enabled:$ipv6_enabled,
	  default_mode:$default_mode, default_dns:$default_dns, default_keepalive:$default_keepalive,
	  endpoint:$endpoint, forward_mode:$forward_mode, public_iface:$public_iface, mtu:$mtu,
	  use_psk:$use_psk, client_isolation:$client_isolation,
	  server_private_key:$server_private_key, server_public_key:$server_public_key,
	  server_ipv4:$server_ipv4, server_ipv6:$server_ipv6, version:$version}' \
	| atomic_write "$WGVPN_CONF" 0600

# --- Hooks (NAT masquerade owned by this project, applied via wg-quick PostUp/Down) ---
phase "Writing firewall hooks"
mkdir -p "${WGVPN_STATE_DIR}/hooks"
cat >"${WGVPN_STATE_DIR}/hooks/postup.sh" <<HOOK
#!/usr/bin/env bash
set -e
${WGVPN_BIN} __internal-fw-apply
HOOK
cat >"${WGVPN_STATE_DIR}/hooks/postdown.sh" <<HOOK
#!/usr/bin/env bash
set -e
${WGVPN_BIN} __internal-fw-remove
HOOK
chmod 750 "${WGVPN_STATE_DIR}/hooks/postup.sh" "${WGVPN_STATE_DIR}/hooks/postdown.sh"

# --- Install program files ----------------------------------------------------
phase "Installing program files"
mkdir -p "${WGVPN_PREFIX}/lib" "${WGVPN_PREFIX}/bin"
cp -f "${SCRIPT_DIR}/lib/"*.sh "${WGVPN_PREFIX}/lib/"
cp -f "${SCRIPT_DIR}/bin/wg-vpn" "${WGVPN_PREFIX}/bin/wg-vpn"
cp -f "${SCRIPT_DIR}/VERSION" "${WGVPN_PREFIX}/VERSION"
chmod +x "${WGVPN_PREFIX}/bin/wg-vpn"
ln -sf "${WGVPN_PREFIX}/bin/wg-vpn" "$WGVPN_BIN"
chmod +x "$WGVPN_BIN"

# --- Render config + sysctl + firewall ----------------------------------------
phase "Rendering WireGuard configuration"
wg_render_server_config
wg_config_syntax_ok || die "Generated WireGuard configuration failed validation."

phase "Configuring IP forwarding"
net_sysctl_enable_forwarding 1 "$([ "$need_ipv6" = "1" ] && echo 1 || echo 0)"

phase "Configuring firewall"
fw_apply "$OPT_PORT" "$OPT_FORWARD_MODE" "$OPT_PUBLIC_IFACE" "$OPT_IPV4_SUBNET" "$OPT_IPV6_SUBNET" "$OPT_CLIENT_ISOLATION"

phase "Starting WireGuard service"
wg_service_enable_start

INSTALL_FAILED_PHASE=""
echo
ok "Installation complete!"
echo
echo "  Manager command:   sudo wg-vpn"
echo "  Add a client:      sudo wg-vpn add-client alice"
echo "  Server status:     sudo wg-vpn status"
echo "  Endpoint:          ${OPT_ENDPOINT}:${OPT_PORT}"
if [ "$OS_SUPPORT_MODE" = "compat" ]; then
	echo
	warn "Reminder: this Ubuntu release runs in compatibility mode (not explicitly tested)."
fi
exit 0
