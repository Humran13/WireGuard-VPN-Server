#!/usr/bin/env bash
# update.sh - self-update from GitHub releases, with backup + rollback
# shellcheck shell=bash

if [ -n "${WGVPN_UPDATE_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
WGVPN_UPDATE_LOADED=1

WGVPN_GH_REPO="Humran13/WireGuard-VPN-Server"
# Overridable for testing against a local/mock release server; production
# installs always use the GitHub defaults above.
WGVPN_GH_API="${WGVPN_GH_API:-https://api.github.com/repos/${WGVPN_GH_REPO}/releases/latest}"
WGVPN_GH_RAW="${WGVPN_GH_RAW:-https://raw.githubusercontent.com/${WGVPN_GH_REPO}/main}"

# version_compare <a> <b>: echoes -1, 0, or 1  (a<b, a==b, a>b) for semver-like strings
version_compare() {
	local a="$1" b="$2"
	if [ "$a" = "$b" ]; then echo 0; return; fi
	local ia ib
	IFS='.' read -r -a ia <<<"${a%%-*}"
	IFS='.' read -r -a ib <<<"${b%%-*}"
	local i n
	n=${#ia[@]}
	if [ "${#ib[@]}" -gt "$n" ]; then n=${#ib[@]}; fi
	for ((i=0; i<n; i++)); do
		local x=${ia[i]:-0} y=${ib[i]:-0}
		x=$((10#$x)); y=$((10#$y))
		if [ "$x" -lt "$y" ]; then echo -1; return; fi
		if [ "$x" -gt "$y" ]; then echo 1; return; fi
	done
	echo 0
}

update_check() {
	local latest
	latest="$(curl -fsSL --max-time 8 "$WGVPN_GH_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)"
	latest="${latest#v}"
	if [ -z "$latest" ]; then warn "Could not reach GitHub to check for updates."; return 1; fi
	echo "$latest"
}

update_run() {
	local latest cmp
	latest="$(update_check)" || return 1
	cmp="$(version_compare "$WGVPN_VERSION" "$latest")"
	if [ "$cmp" -ge 0 ]; then
		ok "Already up to date (installed: ${WGVPN_VERSION}, latest: ${latest})."
		return 0
	fi

	info "Update available: ${WGVPN_VERSION} -> ${latest}"
	confirm "Proceed with update?" y || { info "Update cancelled."; return 0; }

	local backup_file
	info "Backing up current state before updating..."
	backup_file="$(backup_create 2>/dev/null | tail -n1)"
	[ -n "$backup_file" ] || die "Pre-update backup failed; aborting update."

	local staging
	staging="$(mktemp -d "${TMPDIR:-/tmp}/wgvpn-update.XXXXXXXX")" || die "mktemp -d failed"

	if ! curl -fsSL --max-time 20 "${WGVPN_GH_RAW}/install.sh" -o "${staging}/install.sh"; then
		rm -rf -- "$staging"
		die "Failed to download updated installer from GitHub."
	fi
	chmod +x "${staging}/install.sh"

	info "Running updated installer..."
	if WGVPN_NONINTERACTIVE=1 WGVPN_UPDATE_MODE=1 bash "${staging}/install.sh" --non-interactive --assume-yes; then
		rm -rf -- "$staging"
		ok "Updated to version ${latest}."
	else
		err "Update failed; rolling back to pre-update snapshot."
		rm -rf -- "$staging"
		backup_restore_raw "$backup_file"
		die "Update rolled back. Your previous configuration has been restored."
	fi
}
