#!/usr/bin/env bash
# uninstall.sh - remove only project-owned files/rules
# shellcheck shell=bash

if [ -n "${WGVPN_UNINSTALL_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_UNINSTALL_LOADED=1

# uninstall_run <mode: program|full>
uninstall_run() {
	local mode="${1:-program}"

	wg_service_stop 2>/dev/null || true
	fw_remove 2>/dev/null || true
	net_sysctl_remove

	rm -f "$WGVPN_BIN"
	rm -rf -- "$WGVPN_PREFIX"

	if [ "$mode" = "full" ]; then
		rm -f "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
		rm -rf -- "$WGVPN_STATE_DIR"
		ok "Complete removal finished: program, WireGuard interface config, and project state removed."
	else
		ok "Program removed. WireGuard configuration and backups preserved at:"
		echo "  ${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
		echo "  ${WGVPN_STATE_DIR}"
	fi
}
