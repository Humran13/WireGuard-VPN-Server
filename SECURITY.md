# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in WireGuard-VPN-Server, please report
it privately by opening a GitHub Security Advisory on this repository
(Security tab -> "Report a vulnerability"), rather than a public issue.

Please include:
- A description of the vulnerability and its impact
- Steps to reproduce
- The Ubuntu version and wireguard-tools version affected

We aim to acknowledge reports within a few days.

## Scope

This project manages a WireGuard VPN server on Ubuntu. In scope:
- `install.sh` and all `lib/*.sh` modules
- `bin/wg-vpn` manager
- Generated WireGuard configurations, firewall rules, and systemd integration

Out of scope: the upstream `wireguard-tools` / kernel WireGuard implementation
itself (report those upstream at https://www.wireguard.com/).

## Design Notes

- The manager (`wg-vpn`) is root-only and has no network-facing management
  API or web panel.
- Server and client private keys are never printed by any command and are
  stored with `0600` permissions under root-owned directories.
- Per-client preshared keys are enabled by default.
- All user-supplied input (client names, CIDRs, ports, hostnames) is
  validated before use; see `lib/validate.sh`.
- Firewall rules are created in dedicated, clearly-named nftables
  tables/iptables comments so they can be identified and removed without
  touching unrelated host firewall state.
