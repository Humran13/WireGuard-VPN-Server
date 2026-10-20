#!/usr/bin/env bash
# interactive_probe.sh - exercises exactly the prompt_read()/confirm() code
# path used by install.sh's wizard, under the same hostile condition that
# caused the production bug: this file's own text arrives over the
# process's stdin (as happens with `curl | bash`), so if prompt input were
# read from stdin instead of the controlling terminal, the lines below
# would be consumed as answers instead of the real terminal input.
# shellcheck shell=bash
set -euo pipefail

# shellcheck source=/dev/null
source "${WGVPN_TEST_LIB_DIR:?WGVPN_TEST_LIB_DIR must be set}/common.sh"

prompt_read port "Port [51820]: "
port="${port:-51820}"
echo "GOT_PORT=${port}"

prompt_read dns "DNS [1.1.1.1]: "
dns="${dns:-1.1.1.1}"
echo "GOT_DNS=${dns}"

if confirm "Enable PSK?" y; then
	echo "GOT_CONFIRM=yes"
else
	echo "GOT_CONFIRM=no"
fi

echo "PROBE_DONE"

# --- Trailing lines that must NEVER be consumed as prompt answers ------------
# comment-line-after-port
# comment-line-after-dns
# comment-line-after-confirm
exit 0
