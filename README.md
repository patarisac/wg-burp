# wg-burp

[![ci](https://github.com/patarisac/wg-burp/actions/workflows/ci.yml/badge.svg)](https://github.com/patarisac/wg-burp/actions/workflows/ci.yml)

Set up a WireGuard tunnel on your machine and route a client device's traffic to Burp Suite
without configuring a proxy on the client.

`wg-burp` automates [`wg-config`](https://github.com/patarisac/wg-config), so you don't have to
set up the WireGuard server by hand.

## Requirements

- **Linux host:** Bash, `nftables`, `wireguard-tools`, and `iproute2`.
- **macOS host (experimental):** Homebrew `wireguard-tools`, Bash 4+, and one-time PF setup by an
  administrator. Follow the [macOS guide](https://github.com/patarisac/wg-burp/blob/main/docs/macos.md) first.
- Burp Suite and administrator access on the host; a WireGuard app on the client. Install
  `qrencode` on the host for QR import, or transfer the generated profile as a file.

## Install

```bash
git clone https://github.com/patarisac/wg-burp.git
cd wg-burp
sudo ./install.sh
```

Use `sudo ./install.sh --dry-run` to preview the install or `sudo ./install.sh --uninstall` to remove it.

## Quick start

1. Run `wgb doctor` (`sudo wgb doctor` on macOS to check PF), then `sudo wgb up`.
2. In Burp, add a Proxy listener on port `8083` bound to the WireGuard server address
   (default `10.13.37.1`). Enable **Support invisible proxying** and turn intercept off for the
   smoke test. A listener bound only to `127.0.0.1` won't receive redirected traffic.
3. Import the generated QR or `.conf` file on a client that can reach the host, and activate the
   tunnel. Leave the client's proxy settings off.
4. Run `sudo wgb wait` to confirm the handshake. Send a plain HTTP request to an authorized test
   endpoint and confirm it appears in **Proxy > HTTP history** in Burp.
5. Run `sudo wgb down` when finished. It keeps client profiles; use `sudo wgb down --purge` to
   also remove the current session's generated configs and profiles.

**Keep profiles private.** They contain private keys and are written under `./out` by default,
relative to where you run `wgb up`. Don't commit them.

## Help and limits

- Run `wgb --help` for options, or see the [troubleshooting guide](https://github.com/patarisac/wg-burp/blob/main/docs/troubleshooting.md)
  for installer, DNS, and connectivity issues.
- The tunnel forwards IPv4. Use `--no-proxy` for tunnel-only use. For HTTPS, `wgb ca` explains how
  to trust the Burp CA on a test client. Certificate pinning can still prevent interception.
- Native macOS CI verifies HTTP delivery to a test listener and teardown, not Burp forwarding or
  HTTPS interception.

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and [SECURITY.md](SECURITY.md) for private reporting.

[MIT License](LICENSE). Built with AI assistance.
