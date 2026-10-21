# Testing

This project is tested at four levels. Each level tells you something
different — read the "proves" / "does not prove" lines carefully rather than
assuming a green check means "WireGuard definitely works on every listed OS."

## 1. Static analysis

- `bash -n` on every shell file (syntax only).
- [ShellCheck](https://www.shellcheck.net/) with `-x` (follows sourced
  files) across `install.sh`, `bin/wg-vpn`, and `lib/*.sh`. The project
  `.shellcheckrc` disables a small set of checks that are structural false
  positives for this codebase's module-sourcing pattern (documented inline
  in that file) — it does not suppress anything else.

Run locally:

```bash
shellcheck -x install.sh bin/wg-vpn lib/*.sh
```

## 2. Unit tests (Bats)

`tests/*.bats` cover pure/isolated logic: Ubuntu version parsing and support
classification (including the "future release -> compatibility mode" path),
IPv4/IPv6/CIDR/port/hostname/peer-name/base64-key validation (including
malformed and hostile input), CIDR math and overlap detection, IPv4/IPv6
address allocation and duplicate avoidance, route-overlap detection between
site-to-site peers, semantic version comparison, and backup-archive
validation (including explicit path-traversal rejection).

```bash
bats tests/
```

## 3. Install/config tests (per Ubuntu release)

The full non-interactive installer (`install.sh --non-interactive
--assume-yes ...`) is run to completion inside a **systemd-enabled** Ubuntu
container for each of 18.04, 20.04, 22.04, 24.04, and 26.04, followed by:
`wg-vpn add-client`, `list-clients`, `diagnostics`, an idempotent re-run of
the installer (verifying it detects the existing install and repairs in
place without destroying clients or regenerating keys), and a full
uninstall + clean reinstall.

**This proves:** package installation succeeds, key generation and config
rendering are correct, the systemd unit starts and stays active, the
manager's CLI works, diagnostics reports 0 FAIL, and the installer is safely
rerunnable — on all five releases.

**This does not prove:** that each release's *own* default kernel ships
WireGuard support out of the box — containers share the host/CI runner's
kernel, not the guest distribution's. See the real networking test below for
what actually exercises the kernel module.

The CI workflow (`.github/workflows/ci.yml`) runs a lighter version of this
per-release check (package install + config generation + client management)
without systemd, since GitHub-hosted runner containers don't provide one;
the installer detects that and skips the service-start step with a warning
rather than failing.

## 4. Real WireGuard networking test

`tests/e2e/tunnel_test.sh` is a genuine end-to-end test using Linux network
namespaces (`ip netns`) on a host where the WireGuard kernel module is
actually available (not just a container sharing a kernel). It builds three
namespaces - a server, a road-warrior client, and a router namespace
standing in for "the public internet" (so traffic between them is genuinely
routed, not exchanged over one shared link) - runs this project's *real*
`install.sh` and `wg-vpn add-client`/`export` inside the server namespace,
imports the generated client config in the client namespace exactly as a
real WireGuard client would, and verifies with real packets:

- A real Noise-protocol handshake completes on both sides
- The client can ping the server's own WireGuard address
- The client can reach an address that only exists behind the server's
  NAT/forward path (full-tunnel internet access through the VPN)
- A DNS query against the installer-configured DNS server resolves
  through the tunnel
- `PersistentKeepalive` is present in the generated client config
- The client config's `PresharedKey` presence matches the `use_psk` setting

Run it (needs root and a kernel with WireGuard support - `ip link add test0
type wireguard` must succeed):

```bash
sudo bash tests/e2e/tunnel_test.sh --mode=full4 --use-psk=1
```

Pass `--keep` to leave the namespaces and generated files in place for
manual inspection (`ip netns exec <ns> ...`) instead of tearing them down.

All resources are created inside dedicated namespaces and cleaned up
afterward (unless `--keep` is used); the test never touches the host's own
networking.

**Not covered:** live IPv6 tunnel traffic, the Ubuntu 18.04
WireGuard-PPA/DKMS fallback code path, and live peer revocation / restart
persistence under real traffic (covered functionally by `tests/peers.bats`
and the install-matrix idempotency checks, but not with a live tunnel).

## Idempotency, backup/restore, and uninstall

Verified as part of the per-release matrix above: rerunning the installer
does not regenerate server keys, duplicate firewall rules, or destroy
existing clients; `wg-vpn backup` followed by deleting a client followed by
`wg-vpn restore` recovers the exact prior client list; `wg-vpn uninstall`
(program-only) preserves `/etc/wireguard-vpn-server` and
`/etc/wireguard/wg0.conf`, while `wg-vpn uninstall --full` removes them, and
a subsequent clean install succeeds.
