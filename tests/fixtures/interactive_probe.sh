#!/usr/bin/env bash
# interactive_probe.sh - exercises exactly the prompt_read()/confirm() code
# path used by install.sh's wizard, under the same hostile condition that
# caused the production bugs: this file's own text arrives over the
# process's stdin (as happens with `curl | bash`), so:
#
#   1. if prompt input were read from stdin instead of the controlling
#      terminal, the trailing comment lines below would be consumed as
#      answers instead of the real terminal input (the original bug), and
#
#   2. if opening the controlling terminal ever clobbers this script's own
#      stderr as a side effect, every prompt after the first (and every
#      warn()/err() call) silently stops being displayed, even though
#      answers still arrive correctly underneath - which looks exactly
#      like the installer hanging (the second, later bug).
#
# The prompt strings below are copied verbatim from install.sh's wizard;
# tests/interactive_install.bats independently greps install.sh to make
# sure they haven't drifted out of sync.
# shellcheck shell=bash
set -euo pipefail

# shellcheck source=/dev/null
source "${WGVPN_TEST_LIB_DIR:?WGVPN_TEST_LIB_DIR must be set}/common.sh"

prompt_read mchoice "Select [1-6, default 1]: "
case "${mchoice:-1}" in
	1) mode="full4" ;;
	2) mode="full6" ;;
	*) mode="full4" ;;
esac
echo "GOT_MODE=${mode}"

prompt_read v "WireGuard UDP port [51820]: "
port="${v:-51820}"
echo "GOT_PORT=${port}"

prompt_read v "Client DNS (comma-separated, blank for none) [1.1.1.1]: "
dns="${v-1.1.1.1}"
echo "GOT_DNS=${dns}"

prompt_read fchoice "Select [1-2, default 1]: "
[ "${fchoice:-1}" = "2" ] && forward_mode="routed" || forward_mode="nat"
echo "GOT_FORWARD=${forward_mode}"

if confirm "Enable per-client preshared keys (recommended)?" y; then
	echo "GOT_PSK=yes"
else
	echo "GOT_PSK=no"
fi

if confirm "Isolate clients from each other (block peer-to-peer traffic)?" y; then
	echo "GOT_ISOLATION=yes"
else
	echo "GOT_ISOLATION=no"
fi

prompt_read v "Detected public endpoint [203.0.113.10] (press Enter to accept, or type a different host/IP): "
endpoint="${v:-203.0.113.10}"
echo "GOT_ENDPOINT=${endpoint}"

# A warn() call after several prompts: this must still be visible. It was
# not (silently swallowed) under the stderr-clobbering bug, since opening
# /dev/tty via a bare `exec ... 2>/dev/null` permanently redirected this
# script's own stderr - not just the one open attempt - to /dev/null.
warn "probe warning after prompts"

echo "PROBE_DONE"

# --- Trailing lines that must NEVER be consumed as prompt answers ------------
# comment-line-after-mode
# comment-line-after-port
# comment-line-after-dns
# comment-line-after-forward
# comment-line-after-psk
# comment-line-after-isolation
# comment-line-after-endpoint
exit 0
