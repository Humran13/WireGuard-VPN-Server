# Changelog

All notable changes to this project are documented in this file.

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
