# WireGuard VPN Server Manager

A production-ready installer and management tool for a native **WireGuard**
VPN server on Ubuntu. One command installs it, a friendly terminal manager
runs it.

WireGuard is a UDP-based VPN protocol built into the Linux kernel. This
project does not add TCP/TLS/WebSocket/SSH wrappers, obfuscators, or any
other transport layer — it is a straightforward, reliable native WireGuard
server, plus the tooling to install, configure, and operate it.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/WireGuard-VPN-Server/main/install.sh | sudo bash
```

This launches an interactive wizard (connection mode, port, DNS, forwarding
mode, etc.) with sensible defaults. For automated/CI/VPS-provisioning use:

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/WireGuard-VPN-Server/main/install.sh \
  | sudo bash -s -- --non-interactive --assume-yes \
      --mode=full4 --port=51820 --dns=1.1.1.1 --forward-mode=nat
```

Run `install.sh --help` for the full list of flags. The installer is
idempotent — rerunning it on an existing installation offers to open the
manager, repair, update, or reinstall, and never destroys an existing working
configuration.

## Manager

```bash
sudo wg-vpn
```

Opens an interactive menu (server status, add/list/show/enable/disable/delete
clients, QR codes, export configs, site-to-site peers, server & routing
settings, restart, diagnostics, logs, backup/restore, update, repair,
uninstall). Every action is also a direct CLI subcommand:

```bash
sudo wg-vpn status
sudo wg-vpn add-client alice
sudo wg-vpn list-clients
sudo wg-vpn show-client alice
sudo wg-vpn qr alice
sudo wg-vpn export alice ./alice.conf
sudo wg-vpn disable-client alice
sudo wg-vpn enable-client alice
sudo wg-vpn delete-client alice
sudo wg-vpn diagnostics
sudo wg-vpn logs
sudo wg-vpn restart
sudo wg-vpn backup
sudo wg-vpn restore /path/to/backup.tar.gz
sudo wg-vpn repair
sudo wg-vpn update
sudo wg-vpn uninstall [--full]
sudo wg-vpn version
```

## Supported Ubuntu versions

Explicitly tested: **18.04, 20.04, 22.04, 24.04, 26.04** (LTS releases).
Any other Ubuntu release `>= 18.04` is accepted and installed in a
**compatibility mode**, with a clear notice that it has not been explicitly
tested. Ubuntu 18.04 uses whichever of the following works on the running
kernel: the native `wireguard`/`wireguard-tools` packages from Ubuntu's
repositories, or (if unavailable) the official WireGuard PPA with the DKMS
module. The installer never silently substitutes an unrelated VPN
implementation.

## Supported CPU architectures

`amd64` (x86_64) and `arm64` (aarch64), via Ubuntu's own packages. Other
architectures Ubuntu supports may work but are not explicitly tested or
claimed here.

## Connection / routing modes

Selectable at install time, and per-client where relevant:

| Mode | AllowedIPs (client side) | Notes |
|---|---|---|
| IPv4 full tunnel | `0.0.0.0/0` | default, typical road-warrior VPN |
| IPv6 full tunnel | `::/0` | only offered if the server has working IPv6 |
| Dual-stack full tunnel | `0.0.0.0/0, ::/0` | IPv6 part only if available |
| IPv4 split tunnel | admin-specified IPv4 CIDRs | validated, checked for overlap |
| IPv6 split tunnel | admin-specified IPv6 CIDRs | only if IPv6 available |
| Dual-stack split tunnel | IPv4 + IPv6 CIDRs | |
| Site-to-site / routed peer | remote LAN subnet(s) | advanced, manager-only (menu option 10) |

**Forwarding modes:** NAT/Masquerade (default; the installer auto-detects the
public network interface — it never assumes `eth0`) or Routed/No-NAT
(advanced; you must already have upstream routing in place).

## Client management

Each client gets a unique WireGuard keypair, a preshared key (on by default),
a unique VPN address, and a standard `.conf` file compatible with the
official WireGuard apps for Windows, macOS, Linux, Android, and iOS — no
proprietary config syntax. Removing/disabling a client revokes it from the
live interface immediately (`wg set ... remove`), not just from a file.

## QR codes

```bash
sudo wg-vpn qr alice
```

Renders that one client's config as a terminal QR code (via `qrencode`) for
scanning into WireGuard's mobile apps. Only the requested client's data is
ever shown.

## Firewall

The installer detects nftables or iptables and creates rules in dedicated,
clearly-named tables/comments (`wireguard-vpn-server`) — it never flushes or
replaces your existing firewall. If UFW is active, it adds an allow rule for
the WireGuard port and leaves the rest of your UFW configuration untouched.
Uninstalling removes only the rules this project created.

## IPv4 / IPv6 behavior

IPv6 modes are only offered/enabled when the server actually has working
IPv6 connectivity (checked at install time). The installer will never claim
IPv6 works when it doesn't, and falls back to IPv4-only if you select an
IPv6 mode on a server without it.

## Updating

```bash
sudo wg-vpn update
```

Checks the latest GitHub release, backs up current state, applies the
update, and automatically rolls back if anything fails. Server keys, peers,
and settings are always preserved.

## Backup & restore

```bash
sudo wg-vpn backup
sudo wg-vpn restore /etc/wireguard-vpn-server/backups/wgvpn-backup-<timestamp>.tar.gz
```

Restore validates the archive first (rejects path traversal, requires the
expected layout), takes a safety snapshot of the current state before
touching anything, and rolls back automatically if the restored config fails
validation.

## Uninstall

```bash
sudo wg-vpn uninstall          # remove the program, keep WireGuard config + backups
sudo wg-vpn uninstall --full   # complete removal, including all clients and keys
```

Only removes files, firewall rules, and the sysctl file this project
created. It does not touch unrelated packages or host networking.

## Troubleshooting

Start here:

```bash
sudo wg-vpn diagnostics
```

Reports PASS/WARN/FAIL for privileges, OS/kernel, `wg`/`wg-quick`,
configuration validity, service state, listening port, forwarding, default
interface, endpoint, firewall/NAT, duplicate addresses, and recent systemd
errors. Private keys are never printed by any command.

```bash
sudo wg-vpn logs        # recent journalctl output for the WireGuard service
sudo wg-vpn repair      # re-applies config/permissions/firewall/sysctl without touching clients
```

## Security notes

- Per-client preshared keys are enabled by default.
- Server/client private keys are stored with `0600` permissions under
  root-owned directories and are never printed by any command.
- All user input (names, CIDRs, ports, hostnames, keys) is validated before
  use; config files are written atomically.
- The manager has no network-facing API or web panel — it is local,
  root-only, invoked as `sudo wg-vpn`.
- See [SECURITY.md](SECURITY.md) for the vulnerability reporting process.

## Layout

```text
install.sh              interactive + non-interactive installer
bin/wg-vpn               manager (TUI + CLI subcommands)
lib/*.sh                 modular library (os, network, validate, wireguard,
                          routing, firewall, peers, backup, diagnostics,
                          update, uninstall)
/opt/wireguard-vpn-server         installed program files
/etc/wireguard-vpn-server         project state (config.json, clients/,
                                   site-peers/, backups/)
/etc/wireguard/wg0.conf           authoritative WireGuard interface config
/usr/local/bin/wg-vpn             manager entry point
```

## Testing performed / known limitations

- **Static analysis:** ShellCheck (clean, project-wide) and `bash -n` on every
  script.
- **Unit tests:** Bats, covering OS-version parsing/support logic, IPv4/IPv6/
  CIDR/port/name/endpoint validation (including hostile input), address
  allocation and duplicate detection, route-overlap detection, version
  comparison, and backup-archive validation (including path-traversal
  rejection).
- **Install/config tests:** the full non-interactive installer was run to
  completion inside systemd-enabled Ubuntu 18.04, 20.04, 22.04, 24.04, and
  26.04 containers (client add/list, diagnostics, idempotent reinstall,
  backup/restore, full uninstall + clean reinstall all verified per
  release). Containers share the host kernel, so this validates packaging,
  configuration generation, and service integration — not that every
  release's *own* kernel ships WireGuard support out of the box.
- **Real WireGuard networking test:** a genuine end-to-end test using Linux
  network namespaces (not containers sharing a kernel) with the WireGuard
  kernel module actually loaded: real handshakes between a server and two
  clients, encrypted ping across the tunnel, NAT/masquerade forwarding,
  live peer revocation, and full interface/config restart persistence all
  passed.
- **Not tested:** IPv6 live tunnel traffic (validated by unit tests and
  config generation only — no IPv6-capable test host was available); the
  Ubuntu 18.04 WireGuard-PPA/DKMS fallback path specifically (the 18.04 test
  image had the native `wireguard` package available, so the primary path
  was exercised, not the PPA fallback); UFW-specific rule integration
  (validated by code review and the nftables/iptables backends, not by a
  live UFW-enabled host); the actual GitHub self-update flow against a real
  published release.

This is normal, unmodified WireGuard — no censorship-bypass or traffic-
obfuscation claims are made.
