# Troubleshooting

For a connection issue, start with `wgb doctor`, then `sudo wgb wait`. The firewall counters below
refer to Linux. For PF prerequisites, see the [macOS guide](https://github.com/patarisac/wg-burp/blob/main/docs/macos.md).

## Installed, but `sudo wgb` says command not found

`sudo` may use a different PATH from your shell. The installer defaults to `/usr/local/bin` and
can fall back to `/usr/bin` on Linux when the default isn't on `sudo`'s PATH. Preview the destination
with `sudo ./install.sh --dry-run`. On macOS the installer leaves the prefix unchanged; follow the macOS
guide for the elevated PATH requirements. For custom destinations or packaging, see `./install.sh --help`.

Use the default root-owned copy for normal use. `--link` is for development only: anyone who can
modify a linked checkout can change what `sudo` executes. If zsh completion is missing, follow the
installer's `fpath` advice before running `compinit`.

## Start with doctor

`wgb doctor` is read-only. On macOS, use `sudo wgb doctor` to inspect the active PF hooks. On
Linux it reports:

* **capabilities** - `nft`, the wireguard kernel module, `wireguard-tools`, `qrencode`
* **routing** - the WAN interface it would masquerade through, what the endpoint resolves to, whether
  this host actually holds that address, and the current `ip_forward` (and whether IPv6 is present but
  not carried inside the tunnel)
* **listeners** - whether the WireGuard port is free and whether something is listening on the proxy
  port *and on which address* (a proxy bound to `127.0.0.1` blackholes a redirected client)
* **existing state** - an interface or session left from a previous run
* **coexisting firewalls** - any *other* table hooked at `forward` (see below)
* **transport reality check** - if the client cannot reach the endpoint on cellular or corporate Wi-Fi,
  filtered UDP 51820 is far more likely than a configuration error; that needs an obfuscated fallback
  transport (wstunnel/udp2raw), which this tool does not implement.

## Handshake is up, but nothing loads

First send a plain HTTP request to an authorized test endpoint. Go to Burp's Proxy history and check
the listener address, port, and invisible proxying setting if the request is missing. `wgb wait`
confirms a handshake, not that the proxy received any traffic.

On Linux, an nft `accept` isn't terminal across base chains: another table's `forward` hook can
still drop forwarded traffic. Diagnose with the nftables counters:

```bash
sudo nft list table inet wgb
```

* **redirect rule at `packets 0`** - the packet didn't match the redirect: check the client routes,
  source address, tunnel interface, and whether the request used TCP.
* **forward rule counting, masquerade at 0** - the packets are being dropped *after* this tool's chains,
  which is another firewall's policy (below).
* **redirect counting but the proxy log is empty** - the rule matched; the counter alone doesn't prove
  the listener accepted the connection. Check the bind address, listener port, and invisible proxying.
* **DNS DNAT counting but the client cannot resolve** - DoT/Private DNS on the device bypasses port 53.

### Another firewall is dropping forwarded traffic

If the machine also runs ufw, docker, libvirt, Tailscale or a VPN, its forward-hook chain usually has
`policy drop`. When **ufw** is the one doing it, `up` fixes it and `down` undoes exactly that:

    [wgb] allowed forwarded traffic from 10.13.37.0/24 in ufw (inet filter has policy DROP; 'wgb down' removes this again)

The rule (`ufw route allow from 10.13.37.0/24`) is recorded in the session state *and* in a durable
record under `/var/lib/wgb`, so teardown reverts it - including after a reboot. A rule you added
yourself is detected, left alone and never removed. `--no-fix-firewall` keeps it as advice only.

ufw is only touched when it is running **and** one of its own chains is what drops the packets. An
installed-but-inactive ufw is reported and left alone, since its rules are not in play; a DROP policy
inside docker's, libvirt's or Tailscale's chains is named together with the command that product
documents, rather than being credited to ufw. Nothing is changed in a firewall the tool cannot undo.

## Many SSL errors on the client, with the CA trusted

If plain HTTP works but TLS doesn't, check the proxy log and how the client trusts the CA. If both
fail or also stall without the proxy, check connectivity and MTU first. Profiles route `::/0` into
the tunnel, but `wgb` forwards only IPv4. IPv6 is rejected rather than forwarded.

If the errors survive that, check the **MTU** next. A too-high MTU breaks the large first packets of a
TLS handshake while small requests still work - retry with `--mtu 1280` and re-import the profile.

## Reading an alert in the proxy log

`wgb ca` decodes the common ones, because the alert comes from the *client*, not from the proxy:

* `certificate_unknown` / `bad_certificate` - the client refused the proxy's certificate. Trust store
  first, then pinning. Apps that pin fail here and no amount of CA installation helps.
* `handshake_failure` / `protocol_version` - a TLS or cipher mismatch, not a trust problem.
* the connection closing with no alert at all - usually "Support invisible proxying" switched off in the
  proxy, so it could not speak to a client that thinks it is talking to the real server.

If apps show nothing at all while the browser works, suspect pinning or an Android network security
configuration that doesn't trust user-installed CAs. Use `wgb ca` for certificate setup guidance.

## Slowness: "took too long to respond", timeouts

Three causes, three different fixes:

1. **Interception left on for a busy app** - the proxy is in the path of everything; turn intercept off
   while browsing to see whether it is the proxy or the tunnel.
2. **Path MTU** - see above; large responses stall while small ones work.
3. **DNS** - a resolver reachable only over DoT (port 853) bypasses the port-53 redirect, so lookups
   hang. Turning the device's "secure DNS"/Private DNS off fixed the measured case: the lookup was
   being redirected into a proxy that could not speak DoT.

## `wgb wait` timed out

`wait` is the honest check that the client is talking to you, and its timeout message is the playbook -
ordered by how often each cause is real. In short: is the client on a network that can reach the
endpoint (same LAN, or a forwarded UDP port); is another VPN app on the device holding the tunnel; is
the endpoint address the one the client is actually dialling (a profile scanned before the address
changed keeps dialling the old one - `up` warns when that happens).

## The client refuses the profile

A QR or `syntax error in Peer` can indicate a truncated or malformed profile. Re-import the current
`.conf` file or use `wgb qr <name>` to display it again. A stale profile can still import successfully
but fail to handshake if its key no longer matches the configured peer. `wgb list` shows the peers
that exist, and `wgb qr <name>` checks the profile's key against the server config.
