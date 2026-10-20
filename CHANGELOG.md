# Changelog

All notable changes to this project are documented in this file.

## [1.0.1] - 2026-10-20

Bug-fix release.

### Fixed
- Fixed interactive installation when using the documented
  `curl -fsSL ... | sudo bash` command. The wizard's prompts (routing mode,
  port, DNS, forwarding mode, PSK/isolation confirmations, endpoint
  override, and the existing-installation action menu) now read from the
  controlling terminal (`/dev/tty`) instead of consuming the installer's
  own piped source as if it were typed answers. Previously this caused
  prompts such as the port question to silently receive a line of install
  script source (eg. `# --- Validate / derive settings ... ---`) and fail
  with `Invalid port`.
- Corrected `confirm()` in `lib/common.sh`, which used `[ -t 0 ]` to decide
  whether a prompt could be asked interactively. That check is wrong under
  `curl | bash`, since stdin is the script pipe even though the user has a
  real controlling terminal; `confirm()` now uses the same terminal-input
  abstraction (`prompt_read`/`wgvpn_init_tty`) as the rest of the installer.
- Corrected installer failure-phase reporting: a failure during the
  interactive wizard was previously blamed on the earlier "Detecting
  operating system" phase (the last phase marker set before the wizard
  ran). The wizard now sets its own phase ("Interactive configuration" /
  "Selecting installation action") so failures are attributed correctly.
- Fixed an `EXIT` trap collision: `install.sh`'s fetched-sources cleanup,
  `lib/common.sh`'s temporary-file cleanup, and the installer's rollback/
  failure reporter were each registered with a plain `trap ... EXIT`,
  which silently replaces any trap set earlier - so only the last one
  ever ran. In practice this meant fetched source directories
  (`/tmp/wgvpn-src.*` from the `curl | bash` bootstrap) and other internal
  temp files were never cleaned up. All three are now registered through
  a single coordinated exit-hook stack (`wgvpn_on_exit`) and all run.

### Added
- Regression test suite (`tests/interactive_install.bats`,
  `tests/pty_harness.py`) that reproduces the real failure condition: a
  script's own source arriving over a non-seekable pipe (as with
  `curl | bash`) while a separate controlling terminal supplies answers.
  Covers prompt answers taking precedence over piped source, defaults on
  blank input, `confirm()` behavior under a piped stdin, and a fast,
  non-hanging failure when no controlling terminal is available at all.

## [1.0.0] - 2026-09-23

Initial release.

### Added
- Installer (`install.sh`) supporting Ubuntu 18.04, 20.04, 22.04, 24.04, 26.04,
  and future Ubuntu releases >= 18.04 in a "compatibility mode".
- Interactive installation wizard and a fully non-interactive/flag-driven mode
  for CI and automated VPS provisioning.
- Idempotent, rerunnable installer with detection of an existing installation
  (open manager / repair / update / reinstall / cancel).
- Native WireGuard (kernel module) install path per Ubuntu release, including
  the WireGuard PPA/DKMS fallback for Ubuntu 18.04.
- Connection/routing modes: IPv4 full tunnel, IPv6 full tunnel, dual-stack
  full tunnel, IPv4 split tunnel, IPv6 split tunnel, dual-stack split tunnel,
  and site-to-site/routed peers.
- NAT/masquerade and routed (no-NAT) forwarding modes with automatic public
  interface detection.
- `wg-vpn` manager: interactive TUI menu plus non-interactive CLI subcommands
  (`status`, `add-client`, `list-clients`, `show-client`, `qr`, `export`,
  `enable-client`, `disable-client`, `delete-client`, `diagnostics`, `logs`,
  `restart`, `backup`, `restore`, `repair`, `update`, `uninstall`, `version`).
- Per-client preshared keys (default on), client isolation option, optional
  peer-to-peer traffic, configurable DNS/MTU/keepalive.
- QR code client provisioning via `qrencode`.
- nftables/iptables firewall backends with UFW-aware port rules; only
  project-owned rules are created and removed.
- Dedicated sysctl file for IP forwarding, removed cleanly on uninstall.
- Backup/restore with archive validation (rejects path traversal) and
  automatic pre-restore safety snapshot with rollback.
- Diagnostics with PASS/WARN/FAIL reporting; never prints private keys.
- Self-update mechanism with pre-update backup and automatic rollback on
  failure.
- Two-tier uninstall: program-only (preserves WireGuard config/backups) or
  complete removal.
- ShellCheck-clean codebase, Bats unit test suite, and real end-to-end
  WireGuard tunnel tests (network namespaces: handshake, tunnel ping, NAT,
  multi-peer, live revocation, restart persistence).
