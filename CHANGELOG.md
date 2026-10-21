# Changelog

All notable changes to this project are documented in this file.

## [1.0.3] - 2026-10-22

Bug-fix release: handles restrictive host `FORWARD` policies (Docker,
OpenVPN, administrator-configured firewalls).

### Fixed
- **Clients could handshake but had no internet access on hosts with an
  existing restrictive `FORWARD` policy** (confirmed on Ubuntu 24.04 with
  Docker + OpenVPN installed, `FORWARD` policy `DROP`). The project's own
  nftables forwarding chain accepting WireGuard traffic does not guarantee
  that traffic is ultimately forwarded: nftables evaluates every base chain
  hooked to the same point ("forward") independently, in priority order, so
  a separate host-level chain (eg. the one `iptables`/Docker/OpenVPN
  populate) with its own `DROP` policy can still drop the same packets
  after the project's chain already accepted them. Diagnostics previously
  reported everything as healthy in this exact situation.
  Fixed by additionally installing two narrow, project-owned rules at the
  top of the host's real `iptables` `FORWARD` chain (the chain Docker/
  OpenVPN/ufw/administrators actually populate): the configured WireGuard
  interface to the public interface (`ACCEPT`), and the reverse direction
  restricted to `RELATED,ESTABLISHED` traffic only. Existing Docker,
  OpenVPN, UFW, and administrator rules are never modified or reordered.
  `sudo wg-vpn repair` detects and installs these automatically on an
  existing installation; uninstall removes only these project-owned rules.
  Idempotent (safe to repeat), and reconciles correctly if the configured
  public interface ever changes.
- `wg-vpn diagnostics` now checks the host's actual effective `FORWARD`
  policy and whether these compatibility rules are present, instead of
  only checking that the project's own forwarding chain exists (which,
  as above, does not by itself prove traffic gets through).

### Added
- `tests/e2e/firewall_test.sh`: isolated-namespace regression coverage for
  a clean host, an existing `FORWARD DROP` policy, Docker-like chains,
  OpenVPN coexistence, idempotency, cleanup, diagnostics signals,
  public-interface handling (including an interface change), and NAT rule
  correctness.
- `tests/e2e/tunnel_test.sh --simulate-hostile-fw`: runs the full real
  install → client handshake → internet → DNS path against a
  pre-existing Docker-like restrictive `FORWARD` chain.

## [1.0.2] - 2026-10-21

Bug-fix release: a real production VPN-connectivity investigation, plus a
second interactive-installer hotfix.

### Fixed
- **Installer prompts going invisible mid-wizard (looked like a hang).**
  `wgvpn_init_tty()` opened the controlling terminal with a bare
  `exec 3<>/dev/tty 2>/dev/null`. A command-less `exec` applies ALL of its
  redirections to the current shell permanently - not just for that one
  open attempt - so `2>/dev/null` silently and permanently redirected the
  installer's own stderr to `/dev/null` from that point on. Since
  `read -p` prompts, and every `warn()`/`err()`/`die()` message, are
  written to stderr, every prompt after the very first one (and every
  warning or error with it) stopped being displayed entirely, while the
  underlying reads kept working correctly underneath - indistinguishable
  from a hang. Fixed by scoping the redirect to a brace-group command.
- **`use_psk=false` had no effect.** `peer_add()` generated and stored a
  preshared key for every client unconditionally. Exposed a real bug in
  `json_get()` along the way: its jq filter substituted a fallback value
  for ANY falsy JSON value, not just a missing key - so a stored `false`
  was silently read back as `""`, indistinguishable from the key being
  absent. Every other caller's `= "true"` style check happened to survive
  that; a `!= "false"` check did not. Both are fixed.
- **Generated client configs could advertise an unreachable private IP as
  the server's public endpoint.** When every external IP-lookup service
  failed, the installer fell back to the primary address on the default
  network interface with no check on whether it was actually publicly
  routable - on many real cloud/VPS hosts (AWS, GCP, Azure, and others)
  that address is private/NAT'd, and the real public IP is never visible
  to `ip addr` at all. A generated client config/QR code could end up
  with an endpoint nothing on the internet could reach, reproducibly,
  surviving a full uninstall/reinstall. The installer now refuses to use
  an unverified private/reserved address silently: it dies with a clear
  message in `--non-interactive` mode (requiring an explicit `--endpoint`)
  and warns clearly before the interactive confirmation prompt otherwise.
- **Adding/enabling/disabling/deleting a client silently had no effect in
  non-systemd environments.** `wg_apply_peer_live()`/`wg_service_restart()`
  were gated on the systemd unit reporting "active"; in any environment
  without systemd (containers, CI, some minimal/LXC-based VPS images)
  this did nothing at all while still reporting success, leaving the live
  interface completely out of sync with zero errors anywhere. Confirmed
  via a real network-namespace reproduction. Fixed to key off whether the
  WireGuard interface itself exists, independent of systemd.
- **Split-tunnel modes (`split4`/`split6`/`split-dual`) with no network
  given produced an unusable client.** Silently rendered an empty
  `AllowedIPs =`, which `wg`/`wg-quick` reject outright. Now fails clearly
  instead. The documented, installer-default IPv4 full-tunnel path is
  unaffected.

### Added
- A real end-to-end connectivity test (`tests/e2e/tunnel_test.sh`) using
  Linux network namespaces: runs this project's actual `install.sh` and
  `wg-vpn add-client`/`export`, imports the generated config in a separate
  client namespace exactly as a real WireGuard client would, and verifies
  with real packets across a genuinely routed three-namespace topology
  that a Noise handshake completes, the client reaches the server's VPN
  address, reaches the public internet through the server's NAT, and
  resolves DNS through the tunnel.
- `wg-vpn test-client <name>` (and interactive menu option 21): a
  secret-free, server-side connectivity report for one client -
  configured/enabled/loaded-live state, latest handshake, RX/TX, and a
  plain-language interpretation of what that means.
- `wg-vpn diagnostics` now also checks: the endpoint address against
  known private/reserved IPv4 and link-local/ULA IPv6 ranges, and whether
  a hostname endpoint resolves; whether the configured public interface
  still matches the live default-route interface; NAT/masquerade and
  firewall FORWARD rule presence specifically, not just the inbound port
  rule; and prints every client's connectivity report, with one summary
  hint about a possible firewall outside this server (which this software
  cannot see or change) only when there's actual evidence for it.
- Regression tests for every fix above (`tests/interactive_install.bats`,
  `tests/peers.bats`, `tests/validate.bats`, `tests/routing.bats`,
  `tests/diagnostics.bats`).

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
