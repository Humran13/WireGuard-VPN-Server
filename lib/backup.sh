#!/usr/bin/env bash
# backup.sh - safe backup/restore of project + WireGuard state
# shellcheck shell=bash

if [ -n "${WGVPN_BACKUP_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_BACKUP_LOADED=1

# backup_create [dest_dir]: creates a tar.gz containing state + wg conf, mode 600.
backup_create() {
	local dest_dir="${1:-$WGVPN_BACKUP_DIR}"
	mkdir -p "$dest_dir"
	chmod 700 "$dest_dir"
	local ts file
	ts="$(date -u '+%Y%m%d-%H%M%S')"
	file="${dest_dir}/wgvpn-backup-${ts}.tar.gz"

	local stage
	stage="$(mktemp -d "${TMPDIR:-/tmp}/wgvpn-backup.XXXXXXXX")" || die "mktemp -d failed"
	trap 'rm -rf -- "${stage:-}" 2>/dev/null || true' RETURN

	mkdir -p "${stage}/state" "${stage}/wireguard"
	if [ -d "$WGVPN_STATE_DIR" ]; then cp -a "$WGVPN_STATE_DIR"/. "${stage}/state/" 2>/dev/null || true; fi
	rm -rf "${stage}/state/backups"
	if [ -f "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf" ]; then cp -a "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf" "${stage}/wireguard/"; fi
	echo "$WGVPN_VERSION" >"${stage}/VERSION"

	tar -czf "$file" -C "$stage" .
	chmod 600 "$file"
	rm -rf -- "$stage"
	ok "Backup created: ${file}"
	echo "$file"
}

# backup_validate <archive>: sanity-checks contents before restore (no path traversal, expected layout)
backup_validate() {
	local archive="$1"
	[ -f "$archive" ] || die "Backup file not found: $archive"

	local listing
	listing="$(tar -tzf "$archive" 2>/dev/null)" || die "Archive is not a valid tar.gz: $archive"
	[ -n "$listing" ] || die "Archive is empty: $archive"

	# reject absolute paths and path traversal
	if grep -qE '(^|/)\.\.(/|$)' <<<"$listing"; then
		die "Archive contains path traversal entries ('..'); refusing to restore."
	fi
	if grep -qE '^/' <<<"$listing"; then
		die "Archive contains absolute paths; refusing to restore."
	fi
	grep -q '^./VERSION$\|^VERSION$' <<<"$listing" || die "Archive missing VERSION marker; not a wireguard-vpn-server backup."
	grep -qE '^\./state/|^state/' <<<"$listing" || die "Archive missing expected state/ directory."
}

# backup_restore <archive>: validates, then atomically replaces state (with rollback on failure).
backup_restore() {
	local archive="$1"
	backup_validate "$archive"

	local stage
	stage="$(mktemp -d "${TMPDIR:-/tmp}/wgvpn-restore.XXXXXXXX")" || die "mktemp -d failed"

	tar -xzf "$archive" -C "$stage" || { rm -rf -- "$stage"; die "Failed to extract archive."; }
	[ -d "${stage}/state" ] || { rm -rf -- "$stage"; die "Archive missing state/ after extraction."; }

	local pre_backup
	info "Creating safety snapshot of current state before restore..."
	pre_backup="$(backup_create "${WGVPN_STATE_DIR}/pre-restore" 2>/dev/null | tail -n1)"

	wg_service_stop 2>/dev/null || true

	if [ -d "$WGVPN_STATE_DIR" ]; then
		rm -rf -- "${WGVPN_STATE_DIR:?}"/clients "${WGVPN_STATE_DIR:?}"/site-peers "${WGVPN_STATE_DIR:?}"/config.json
	fi
	mkdir -p "$WGVPN_STATE_DIR"
	cp -a "${stage}/state"/. "$WGVPN_STATE_DIR"/ 2>/dev/null
	chmod 700 "$WGVPN_STATE_DIR"

	if [ -f "${stage}/wireguard/${WGVPN_IFACE}.conf" ]; then
		cp -a "${stage}/wireguard/${WGVPN_IFACE}.conf" "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
		chmod 600 "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"
	fi

	rm -rf -- "$stage"

	if wg_config_syntax_ok; then
		wg_service_enable_start
		ok "Restore completed successfully from ${archive}."
	else
		err "Restored configuration failed validation; rolling back to pre-restore snapshot."
		if [ -n "$pre_backup" ]; then backup_restore_raw "$pre_backup"; fi
		die "Restore aborted and rolled back."
	fi
}

# backup_restore_raw: internal, used only for rollback (skips creating another safety snapshot)
backup_restore_raw() {
	local archive="$1"
	local stage
	stage="$(mktemp -d "${TMPDIR:-/tmp}/wgvpn-rollback.XXXXXXXX")" || return 1
	tar -xzf "$archive" -C "$stage" 2>/dev/null || { rm -rf -- "$stage"; return 1; }
	rm -rf -- "${WGVPN_STATE_DIR:?}"/clients "${WGVPN_STATE_DIR:?}"/site-peers "${WGVPN_STATE_DIR:?}"/config.json 2>/dev/null
	cp -a "${stage}/state"/. "$WGVPN_STATE_DIR"/ 2>/dev/null
	if [ -f "${stage}/wireguard/${WGVPN_IFACE}.conf" ]; then cp -a "${stage}/wireguard/${WGVPN_IFACE}.conf" "${WGVPN_WG_DIR}/${WGVPN_IFACE}.conf"; fi
	rm -rf -- "$stage"
	wg_service_enable_start 2>/dev/null || true
}
