# macOS host pilot

The macOS host backend is experimental. Native [GitHub Actions CI](https://github.com/patarisac/wg-burp/actions/runs/44808774569)
verified WireGuard bring-up, repeat `up`, HTTP delivery from an independent WireGuard peer through
PF to a test listener, and cleanup. CI uses a disposable runner's existing PF hook, not the
production `wgb/*` hook, and does not run Burp or test upstream proxy forwarding.

`wgb` delivers matching TCP connections to the configured listener. HTTP/TLS handling, CA trust,
and certificate pinning are outside the tunnel's delivery test. Don't use this on a work Mac until
its administrator approves the PF configuration.

## Requirements

- Homebrew `wireguard-tools` (includes dependencies on `wireguard-go` and modern Bash on macOS),
  and optionally `qrencode`.
- Bash 4 or later. macOS's stock Bash is too old for upstream `wg-quick`. The elevated PATH must
  find the administrator-approved Homebrew tools; if it does not, ask the administrator to configure
  it rather than passing an arbitrary user-controlled PATH to `sudo`.
- A dedicated PF hook in the **active** main ruleset. `wgb` only writes its own child anchor and
  does not change `/etc/pf.conf`, borrow part of Apple's namespace, or reload the main ruleset.
  On an unprepared Mac, `sudo wgb up` fails closed.

For a managed host, the administrator needs to place these directives in the matching NAT,
redirection, and filter sections of the existing ruleset (not at an arbitrary location):

```pf
nat-anchor "wgb/*"
rdr-anchor "wgb/*"
anchor "wgb/*"
```

Placement and existing firewall policy matter. Have the administrator validate and activate the
change through their normal firewall process. Do not replace the main ruleset with this snippet.
`sudo wgb doctor` checks that the active ruleset has all three hooks; it doesn't modify the firewall.

## Pilot workflow

1. Follow the [installation instructions](../README.md#install). Run `sudo wgb doctor` to check the
   WireGuard tools and PF hooks, then `sudo wgb up`. WireGuard listens on UDP `51820` by default.
2. In Burp, bind the Proxy listener to the WireGuard server address (default `10.13.37.1`) on
   TCP `8083` and enable **Support invisible proxying**. Turn intercept off for the smoke test.
3. Import the generated profile into a separate device on the same network, without configuring an
   explicit proxy on that device. Use `sudo wgb wait` for the handshake. Send an HTTP request to an
   authorized test endpoint and check Burp's HTTP history; a handshake alone isn't a pass.
4. Run `sudo wgb down` and verify that forwarding and unrelated rules are unchanged. Plain `down`
   keeps the client profiles; use `sudo wgb down --purge` to remove the current session's profiles too.

If you also want to validate your proxy and client TLS configuration, test HTTPS separately on an
authorized unpinned endpoint with the proxy CA trusted. This is not a `wgb` release requirement.

An unchanged `up` reuses the active session. To change networking settings or use `--fresh`, run
`sudo wgb down` first. A Mac can have one `wgb` session at a time. A killed process can leave a
lock under `/private/var/db/wgb/state-<boot-uuid>/.lock` for the current boot. Look up the UUID with
`sysctl -n kern.bootsessionuuid`. If an administrator has confirmed no `wgb` command is running, remove only
that empty lock directory and retry `sudo wgb down`; keep the other state for cleanup. The tool
does not reuse state or PF enable references after reboot.
`--print-rules` requires a live macOS interface so the output has the correct `utun` name.
