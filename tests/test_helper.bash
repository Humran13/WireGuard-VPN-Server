#!/usr/bin/env bash
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

load_libs() {
	# shellcheck source=/dev/null
	for f in common validate os network routing; do
		source "${REPO_ROOT}/lib/${f}.sh"
	done
}
