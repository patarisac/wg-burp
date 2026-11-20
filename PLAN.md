# wg-burp — Project Plan (living document)

Start with the [README](README.md) for usage and [CONTRIBUTING.md](CONTRIBUTING.md) for test commands.
This plan retains the original Linux design and progress logs as history; their test counts and
release status are checkpoints, not current project metadata.

**Current status:** Linux is supported; macOS is experimental. Native macOS CI verified listener
delivery and cleanup using a test HTTP server. The [macOS guide](docs/macos.md) documents the
one-time PF setup. The next compatibility check is plain HTTP in Burp on an operator's Mac using
the production `wgb/*` hook, followed by teardown. HTTPS decryption is outside the release gate.

---

## Native macOS host implementation plan

**Goal:** Run `wgb` and Burp on macOS as the host, with the same CLI, default profile names,
WireGuard settings, diagnostic workflow and teardown semantics as Linux. Native Windows is out of scope.

**Architecture:** Keep argument parsing, client profiles, keys, QR, session lifecycle and output shared.
Factor out only operating-system primitives: route/listener discovery, forwarding sysctl, live interface
lookup, firewall operations, and install paths. Use Darwin `wg-quick`/`wireguard-go` for the tunnel and
evaluate a narrowly scoped PF anchor for interception. Keep `wgm0` as the logical name and track the
actual Darwin `utun` separately; do not guess which `utun` belongs to the session.

### Milestones

- [x] 1. Baseline and shared preparation (`wgb`, `test/run-tests.sh`): inventory Linux assumptions,
  run lint/unit/installer/integration suites, and isolate shared primitives only where that removes
  duplication. Preserve Linux config and nft goldens.
- [ ] 2. Prove the data path on a disposable Mac: bring up a real tunnel, identify its `utun`,
  prove a scoped PF redirect to the local proxy and non-proxy forwarding/NAT, then remove the anchor
  and restore prior settings. Verify PF compatibility with an existing ruleset and consider a missing
  anchor hook a blocker rather than replacing the system ruleset. Do not publish a dry-run-only port.
- [ ] 3. Integrate the verified primitives (`wgb`, `test/run-tests.sh`, planned
  `test/integration-macos.sh`): keep `up`, `down`, `status`, `doctor`, `wait`, peer edits and QR shared.
  Keep IPv6 fail-fast and QUIC behavior consistent; confirm `--no-proxy` does not redirect. Validate
  rules before applying them and journal resources before changing them. Report unresolved rollback;
  never clear another application's PF rules or disable PF globally as a cleanup shortcut.
- [ ] 4. Installer, docs and CI (`install.sh`, `test/install-test.sh`, `README.md`,
  `docs/troubleshooting.md`, `.github/workflows/ci.yml`): `sudo ./install.sh` and the same `wgb`
  commands. Test Bash version, BSD utilities, secure Homebrew discovery, install/uninstall and
  completion paths. Add macOS checks without reducing Linux coverage.
- [x] 5. Experimental release gate: native macOS WireGuard handshake, HTTP delivery through PF to the
  configured listener without a client proxy setting, repeat `up` without re-keying, and cleanup.
  See run 44808774569 below. Broader support still needs validation on an operator's Mac, including
  the production `wgb/*` hook, Burp HTTP, peer changes, no-proxy forwarding, and failed bring-up.

### macOS validation without a local Mac

- For each Darwin-specific command, flag and output parser, verify against upstream source and the
  target macOS release's own manuals. Record the macOS, architecture, Bash and WireGuard tool versions
  alongside test results. Upstream Darwin `wg-quick` currently requires Bash 4 or newer; verify the
  interpreter that actually runs under `sudo`, not just the interactive shell's version.
- Treat [Apple TN3165](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api)
  as a compatibility constraint: macOS PF is not a stable API. Current OpenBSD syntax is not proof of
  macOS compatibility. Have the target `pfctl` parse generated rules without loading them, and fail
  before changing host networking when requirements are not met.
- Use fixtures and forced-failure tests locally for parsers, preflight and rollback logic; run the Linux
  regression suites. Use a GitHub-hosted macOS runner for native syntax and capability checks where
  possible. Record simulated checks, actual native checks and skipped checks separately.
- Hand the coworker an end-to-end pilot, not a preflight-only build or a manual PF setup exercise.
  Use the same `wgb doctor`, `sudo wgb up`, client import and `sudo wgb down` flow as Linux. After
  preflight, require a request from a separate WireGuard client with no explicit proxy configured to
  appear in Burp's HTTP history for the real-world compatibility check. Verify teardown restores the
  Mac's prior state. HTTPS decryption and CA trust are proxy/client checks, not `wgb` release gates.
  Lint, a parser check and a successful handshake alone do not verify listener delivery.

### Progress and remaining verification

The progress recorded here supersedes earlier intent when they conflict. This workspace is Linux;
Native macOS CI can verify tunnel and listener delivery. Distinguish experimental support from
the real-world compatibility check on an operator's Mac.
No git writes or external publication.

- Milestone 1: `wgb` now checks server config directory modes with one helper that accepts GNU and BSD
  `stat`, and refuses to write if neither can validate the mode. The old GNU-only check silently skipped
  the safety check when `stat -c` failed. Tests exercise the real Linux call, a stubbed BSD call, and
  refusal on error. Before the fix: 181 passed, 3 failed; after: 184 passed, 0 failed. `./test/lint.sh`
  passed (ShellCheck 0.11.0 and zsh parse); `./test/install-test.sh` passed 125 assertions; namespace
  and tunnel suites passed 337 and 43 assertions respectively. No fixture edits: golden comparisons
  pass in the unit suite. The BSD test does not execute a native BSD binary.
- Milestone 2 in progress: `render_pf` produces candidate `nat`, DNS and Burp `rdr`, and tunnel-scoped
  filter rules without mutating the system. Locally verified rule scoping and ordering, mode toggles, and
  refusal of malformed input; the 11 new assertions take `./test/run-tests.sh` to 195 passed, 0 failed.
  `test/macos-pf-check.sh` and the `macos-pf-syntax` Actions job validate proxy, no-proxy, and local-DNS
  variants with native `pfctl` in no-load mode. Bash syntax, ShellCheck and workflow YAML lint pass;
  the native script refused Linux with exit 1 as designed. Installer and Linux integration suites
  passed 125, 337 and 43 assertions respectively. The native [macOS PF syntax job](https://github.com/patarisac/wg-burp/actions/runs/44799551539/job/136507824090)
  passed its no-load validation step. Publication stays with the maintainer. These checks do not
  prove a live data path.
- Milestone 2 still needs native evidence: prove the anchor is reached from the main ruleset, PF
  enablement ownership can be recorded/released, and unrelated rules are preserved. Apple TN3165
  specifically advises against using PF in broadly distributed software; treat this as a controlled
  pilot and reassess before public support. Nothing calls `render_pf` from `wgb up` yet. Do not hand
  this revision to the coworker as an interception build.
- The macOS runner now has a separate WireGuard lifecycle gate. It installs Homebrew's WireGuard
  dependencies, generates a disposable config using the shared renderer, resolves the actual `utun`
  through WireGuard's runtime mapping, and tests bring-up, repeat sync, and teardown. It does not
  enable PF or change forwarding. The [native lifecycle job](https://github.com/patarisac/wg-burp/actions/runs/44802791820/job/136518970027)
  passed, including the disposable tunnel step; the PF syntax job also passed in that run.
  At that revision, the macOS CLI still refused mutating commands.
- Added the `macos-pf-delivery` gate. It sends an HTTP request through a real WireGuard peer with an
  independent userspace TCP/IP stack, so the peer's source IP is not owned by the runner. The runner
  uses an existing PF wildcard hook and a unique test-only child anchor; it refuses to replace the
  root ruleset if the hook is absent. The test requires a handshake, a matching response and the
  peer source address in the listener's log. Cleanup flushes only the child's NAT/filter rules,
  releases only the test's PF enable reference, removes the tunnel, and compares PF and forwarding
  state. This is an HTTP listener, not Burp, and does not test outbound NAT or HTTPS. The child under
  `com.apple` is only for the disposable runner, not a production integration decision.
- Locally verified the Go peer on Linux through a real WireGuard interface and nftables redirect in
  an isolated network namespace (HTTP 200, expected body and client source, nonzero handshake).
  The peer cross-compiles for Darwin arm64. The [live macOS delivery job](https://github.com/patarisac/wg-burp/actions/runs/44804251721/job/136523975850)
  also passed its delivery and cleanup step. Production PF integration, outbound NAT, and actual
  Burp HTTP/HTTPS acceptance remain open.
- The pilot now calls the macOS backend from the shared `up`, `down`, peer and profile flow. It uses
  a dedicated, pre-existing administrator-owned `wgb/*` hook in the main PF ruleset. It never
  edits or reloads the main ruleset, and refuses a stock Mac without those hooks. This is a one-time
  host prerequisite, so zero-setup parity is not met yet. The `com.apple` hook remains confined to
  the disposable CI harness. `docs/macos.md` documents this distinction.
- The delivery CI harness now uses the real CLI dispatcher, including `up` twice, the generated peer
  profile, `wait`, and `down --purge`. Its native run on this revision is pending. Actual Burp,
  outbound NAT and the production hook have not been validated on an operator's Mac.
- Run 44806782219 failed the session path ownership check before the PF delivery test brought up
  WireGuard. The macOS runtime parent `/private/var/run` can be group-writable (`root:daemon`, 0775).
  Move the default and CI workspace to `/private/var/db` without relaxing the guard. Scope the default
  journal to the boot UUID, and report the specific path component rejected by the guard. Native
  verification of the revised delivery job is pending.
- [Run 44808774569](https://github.com/patarisac/wg-burp/actions/runs/44808774569) passed all three
  native macOS jobs, including the revised live PF delivery and cleanup step. This closes the
  HTTP-only gate for the experimental release. It does not validate the production hook, Burp
  forwarding, or TLS interception. No additional proxy dependency or HTTPS test is needed for this gate.

---

## 1. Goal

`wg-burp` is a **single-file bash script** (`wgb`) that stands up a WireGuard tunnel on
the pentester's own laptop and hands the tester a phone-ready client config, so that a
mobile app's traffic is forced through **Burp Suite on the laptop** within seconds and
can be torn down cleanly afterwards.

It replaces the previous browser-based configuration generator
(`https://github.com/patarisac/wg-config` → local clone at `~/repo/wg-config`).
That repo stays alive, untouched, as its own project. **Do not modify wg-config from
this project.** This project is a separate repo.

Workflow being automated:

```
[ phone: WireGuard app ]  ==encrypted UDP==>  [ laptop: wg interface ]
                                                    |  (nft redirect)
                                                    v
                                        [ Burp Suite listener :8083 ]
```

Why this exists rather than "just use the web generator": the web page gives you text
you must then hand-copy into `/etc/wireguard/`, hand-run iptables, hand-remember the
gotchas. The script collapses all of that into `wgb up`, is idempotent, and detects the
things that silently break the workflow (see §13).

---

## 2. Locked decisions

These were decided explicitly by the user or argued and accepted. **Do not re-litigate
without new evidence.**

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Two-layer architecture: pure `render_*` functions + separate `apply_*` layer | Makes config generation testable with no root, no tunnel, no network. The web tool was untestable by construction; this is the main technical argument for the rewrite. |
| D2 | **Firewall = one owned nftables table `inet wgb`**, created/deleted atomically. **No iptables, no PostUp/PostDown rule juggling.** | iptables on Kali/Debian/Sparky is the nft shim anyway (verified: iptables v1.8.13 nf_tables), so there is no portability gain from iptables, while nft gives atomic teardown (`nft delete table inet wgb` = whole cleanup) and no add/delete drift. The web tool's `-A`/`-D` + `-I`/`-D` pairs leave orphan rules after an unclean exit (index.html:1145-1158). |
| D3 | Scope = **ephemeral, laptop-side, on-site use**. No ssh/VPS provisioning in v1. | The real use case is "phone in hand, Burp already running, tunnel up in 20 seconds". VPS provisioning drags in host keys, remote sudo, partial-failure rollback — double the code for the less common case. |
| D4 | Primary use case = **transparent proxy for mobile app testing**; the catch-all TCP redirect to Burp is the core feature, not an option. | User-confirmed. `--no-proxy` still exists for plain-tunnel work. |
| D5 | **Script/command name: `wgb`.** Repo `wg-burp`, local path `~/repo/wg-burp`. | User chose the repo name. Rename is a one-line change if he wants `wgm`. |
| D6 | **MIT license**, copyright holder `patarisac` (matches the GitHub account). | User's choice. |
| D7 | **All user-facing output in English** (help, prompts, errors, README). | User's choice; note the old web tool's README/UI are Indonesian — do not copy that convention here. |
| D8 | Local git repo only. **The user pushes to GitHub himself.** | No `gh` CLI on the box; do not install or push. |
| D9 | Interface name default **`wgm0`** (never `wg0`). | Never fight the tester's own pre-existing tunnel. |
| D10 | Client `AllowedIPs` default **`0.0.0.0/0, ::/0`**. | A carrier-IPv6 phone leaks around a v4-only tunnel; the proxy history becomes a lie. Send v6 into the tunnel and let it die there (no server-side v6 forwarding in v1). |
| D11 | **`--block-quic` defaults ON** (drop UDP 443 from the tunnel). | QUIC/HTTP3 bypasses a TCP proxy entirely; apps silently do nothing in Burp. Forcing TCP fallback is the correct default for a proxy-based workflow. |
| D12 | Client DNS default `1.1.1.1` + server-side port-53 DNAT as a safety net. | Same as the web tool. Catches apps that hardcode a resolver. |
| D13 | MTU default **1380** on both server and client, `--mtu` to override. | Cellular path MTU is lower than 1420; the failure mode is a silent TLS hang with no error, which gets misdiagnosed as "Burp is broken". |
| D14 | Test runner is **dependency-free bash** (`test/run-tests.sh`), not bats. | `bats` is not installed anywhere (verified on this box) and CI simplicity matters; the runner is ~40 lines. bats remains an option later, not a requirement. |
| D15 | Test-only key injection happens by **sourcing the script** (`BASH_SOURCE != $0` ⇒ lib mode), never via test-only CLI flags. | Keeps `render_*` genuinely pure and stops the public CLI from growing test scaffolding. |
| D16 | Behavioural compatibility with the web tool where it was sane: subnet `10.13.37.0/24`, server `.1`, clients from `.2`, WG port `51820`, Burp port `8083`, `PersistentKeepalive = 25`. | Continuity with an environment the user already uses. |
| D17 | **Endpoint default: the detected public address only when this host actually holds it; otherwise the host's main local (LAN/WLAN) address**, with the public alternative and what a port forward would need printed alongside. `--endpoint` always wins. | An address the host does not hold belongs to a NAT that must be configured to forward the port, so defaulting to it hands over a profile that cannot connect while every local check reports success. The LAN address is the one answer that works with no extra infrastructure. User-directed change (2026-10-29), extending §13.10. |

---

## 3. Open questions / pending decisions

1. **Git identity** is unset on this machine (`git config user.name/user.email` both empty
   in the repo). The first commit must be made by the user, or he must tell the agent
   which name/email to set **for this repo only** (`git config --local`).
2. Server-side resolver: v1 keeps the DNAT-to-public-DNS design. A later version could run
   dnsmasq/unbound on the tunnel IP so queries are attributable to the tunnel (useful for
   DNS-exfil observation) — deferred, see §17.
3. Whether `wgb` should later gain a UDP-obfuscated transport (wstunnel/udp2raw) for
   hostile Wi-Fi. Deferred, §17, but the interface should not *preclude* it.
4. Correlation with the Burp-side workflow: whether to auto-detect a running Burp process
   (it can, via `ss -ltnp` port match only) — v1 does the port check, nothing more.

---

## 4. Environment facts (verified 2026-10-24)

Host: Kali, bash 5.3.15, git 2.53.0.

| Tool | State | Consequence |
|------|-------|-------------|
| `bash` 5.3.15 | present | target interpreter; `#!/usr/bin/env bash` |
| `ip` | present (`/usr/sbin/ip`) | used for WAN/link detection |
| `iptables` | present, **v1.8.13 (nf_tables)** | confirms D2: it is the nft shim |
| `nft` | present (`/usr/sbin/nft`) | the firewall backend we actually use |
| `wireguard` kernel module | present (`/lib/modules/7.1.5+kali-amd64/.../wireguard.ko.xz`) | tunnel is possible |
| `wg`, `wg-quick` | **NOT installed** | script must detect + offer to install (`wireguard-tools`), never assume |
| `qrencode` | installed during this session (4.1.1) | QR output; still must have a fallback path (see §11) |
| `shellcheck` | installed during this session (0.11.0) | CI lint gate, run before reporting any milestone done |
| `bats` | **NOT installed** | why D14 |
| `gh` | **NOT installed** | why D8 |
| sudo | works in this development environment without an interactive password (the harness injects it) | run plain `sudo <cmd>`. **Piping a password to `sudo -S` fails** - the terminal layer consumes it - so privileged input goes through a temp file (`sudo nft -c -f <file>`). Never print the secret. |

The user's other machines: SparkyLinux (Debian-based) and Debian/Kali generally. The
script must therefore work on anything Debian-family with nftables, and must degrade
politely when `wg`, `nft`, or `qrencode` are absent.

Sibling project for reference: `~/repo/wg-config` (the web generator).

---

## 5. Reference: existing web tool (behaviour to preserve / reject)

Web tool defaults (from `~/repo/wg-config/index.html`):

| Field | Default | Line |
|-------|---------|------|
| Server endpoint | `192.168.0.10` | index.html:757 |
| Listen port | `51820` | index.html:764 |
| Burp port | `8083` | index.html:772 |
| Allowed IPs | `0.0.0.0/0` | index.html:790 |
| Server subnet base | `10.13.37.` (server `.1/24`, clients `.2+`) | index.html:792 |
| Client DNS | `1.1.1.1` | index.html:796 |
| WAN interface | `wlan0` | index.html:800 |
| Client count | `1` | index.html:804 |
| Key format | `nacl.box.keyPair()` → base64 | index.html:1100-1117 |

Web tool's generated **server-side rules to REJECT** (index.html:1145-1158) — quoted here
so nobody copies them back in:

```
PostUp = iptables -t nat -A POSTROUTING -s 10.13.37.0/24 -o wlan0 -j MASQUERADE
PostUp = iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
PostUp = iptables -t nat -A PREROUTING -i %i -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1
PostUp = iptables -t nat -A PREROUTING -i %i -p tcp -j REDIRECT --to-port 8083
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostUp = iptables -I FORWARD -o %i -j ACCEPT
PostDown = <the six mirror-image deletes>
PostDown = sysctl -w net.ipv4.ip_forward=0
```

Three things it got wrong, all of which the new script fixes:
* no ordering guarantee/reconciliation — duplicate and orphan rules accumulate;
* `-I FORWARD` (insert) paired with `-D FORWARD` (delete) mismatches and silently fails;
* `PostDown` forces `ip_forward=0`, clobbering a global setting the user's other work may
  depend on. `wgb` restores the **prior** value from its state file.

What it got right and we keep: DNS rules ordered *before* the catch-all TCP redirect;
`MASQUERADE` (not `SNAT`); `PersistentKeepalive = 25`; server `.1`, clients `.2+`.

---

## 6. Architecture

Hard boundary, enforced by convention:

```
render layer (pure, no side effects, no root)     apply layer (root, mutating)
  render_server_conf()                              writes /etc/wireguard/<iface>.conf
  render_client_conf(name, addr, priv)              writes client confs + QR
  render_nft()                                      nft -f - (atomic load)
  render_plan()   (dry-run text)                    ip link / wg setconf / state file
```

* `--dry-run` and `--print-config` exercise only the render layer.
* Script is **sourced as a library by the tests** (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`
  guard both for `set -euo pipefail` and for `main`), so tests set globals then call
  render functions. No test-only CLI flags (D15).
* Globals carry resolved config (`IFACE`, `SUBNET`, `DNS`, `LISTEN_PORT`, `BURP_PORT`,
  `MTU`, `WAN_IFACE`, `ENDPOINT`, `ALLOWED_IPS`, `PROXY_MODE`, `BLOCK_QUIC`,
  `CLIENT_COUNT`, `SERVER_PRIVKEY`, `SERVER_PUBKEY`, `CLIENT_NAMES[]`,
  `CLIENT_PRIVKEYS[]`, `CLIENT_PUBKEYS[]`, `CLIENT_ADDRS[]`).

Shell-strictness rule (important, keeps tests from mutating the caller's shell):

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi
```

---

## 7. Target file layout

```
~/repo/wg-burp/
  PLAN.md                 this file
  wgb                     the product: single-file bash script, executable
  README.md               English, script-oriented (written at M5)
  LICENSE                 MIT, "Copyright (c) 2026 patarisac"
  .gitignore              out/, *.conf, *.png, scratch
  .github/workflows/ci.yml   shellcheck + test/run-tests.sh
  test/
    run-tests.sh          dependency-free runner (no bats)
    golden/
      server.conf         golden fixture (fixed test keys)
      client.conf         golden fixture
      rules.nft           golden fixture
  out/                    generated client confs + QR PNGs (gitignored)
```

---

## 8. CLI surface (final)

```
wgb up [--clients N] [--burp-port 8083] [--dns 1.1.1.1] [--mtu 1380]
       [--no-proxy] [--allow-quic] [--endpoint IP] [--iface wgm0]
       [--subnet 10.13.37.0/24] [--listen-port 51820] [--dry-run|--print-config]
wgb down [--purge]        # drop nft table, del link, restore prior sysctl, keep|delete confs
wgb status                # wg show + nft table + leak sanity check
wgb doctor                # read-only preflight; mutates nothing
wgb list                  # peers, addresses, last handshake
wgb add-client NAME       # next free IP; existing peers untouched  <-- key win over web tool
wgb remove-client NAME
wgb qr NAME [--png]
wgb wait [--timeout 120]  # block until a handshake lands, then "fire away"
wgb ca                    # Android CA reality check / instructions
wgb version | --help
```

Exit codes: `0` ok, `1` runtime/verify failure, `2` usage error. (`3` was the stub code the M1
milestones used so a stub could never be mistaken for success; no verb returns it any more, and
`--help` no longer advertises it.)

`wgb add-client` is the functional win over the web page: the web tool regenerates **all**
profiles and **all** keys on every generate, so adding a second phone means re-importing
the first one.

---

## 9. Firewall design — one owned nft table

Rendered verbatim by `render_nft()`; loaded with `nft -f -`; destroyed with
`nft delete table inet wgb`. Order matters: the two port-53 rules **must** precede the
catch-all TCP redirect.

```
# generated by wgb 0.1.0 — do not edit; re-run `wgb up`
table inet wgb {
	chain pre {
		type nat hook prerouting priority dstnat; policy accept;
		ip saddr 10.13.37.0/24 udp dport 53 dnat to 1.1.1.1
		ip saddr 10.13.37.0/24 tcp dport 53 dnat to 1.1.1.1
		ip saddr 10.13.37.0/24 tcp redirect to :8083
	}
	chain post {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr 10.13.37.0/24 oifname "wlan0" masquerade
	}
	chain fwd {
		type filter hook forward priority filter; policy accept;
		iifname "wgm0" udp dport 443 drop
		iifname "wgm0" accept
		oifname "wgm0" accept
	}
}
```

Conditional rules:
* the two `dport 53` lines are omitted when `$DNS` equals the tunnel server IP
  (`10.13.37.1`) — otherwise they would DNAT to the box itself and blackhole DNS;
* `tcp redirect to :<burp>` omitted when `--no-proxy` (`PROXY_MODE=0`);
* `udp dport 443 drop` omitted when `--allow-quic` (`BLOCK_QUIC=0`).

Why `masquerade` and not `snat`: the laptop's WAN address changes between networks
(tethered, hotel Wi-Fi, phone hotspot) — masquerade tracks it, snat would pin a stale IP.

Teardown is exactly:

```bash
nft delete table inet wgb 2>/dev/null || true
ip link del "$IFACE" 2>/dev/null || true
```

---

## 10. WireGuard config templates

`render_server_conf()` — written to `/etc/wireguard/<iface>.conf`, mode 0600, **no
PostUp/PostDown** (D2). MTU is set on both ends (D13).

```
[Interface]
# generated by wgb 0.1.0 — firewall rules are owned by `wgb` (nft table `inet wgb`)
Address = 10.13.37.1/24, fd13:37::1/64
ListenPort = 51820
PrivateKey = <SERVER_PRIVKEY>
MTU = 1380

[Peer]
# client: client
PublicKey = <CLIENT_PUBKEY>
AllowedIPs = 10.13.37.2/32, fd13:37::2/128
```

`render_client_conf(name, addr, privkey)` — for the WireGuard mobile app:

```
[Interface]
PrivateKey = <CLIENT_PRIVKEY>
Address = 10.13.37.2/32, fd13:37::2/64
DNS = 1.1.1.1
MTU = 1380

[Peer]
PublicKey = <SERVER_PUBKEY>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = <endpoint>:51820
PersistentKeepalive = 25
```

Keys: `wg genkey | tee priv | wg pubkey` (real tooling, not a browser JS lib).

---

## 11. Client management, key handling, output

* Client confs are written to `./out/<timestamp>/<name>.conf`, mode 0600, **chowned to
  `$SUDO_USER`** so the tester (not root) owns them — they get copied to phones after all.
* `wgb qr NAME` → `qrencode -t ANSIUTF8` to the terminal, plus a PNG next to the conf.
* `qrencode` missing ⇒ fallback: print the conf and the exact
  `adb push out/.../client.conf /sdcard/Download/` line, because the WireGuard app imports
  `.conf` files from storage — QR is not the only path.
* The server private key is never echoed to stdout unless explicitly requested; client
  privkey material only ever lands in its own 0600 conf.
* IP allocation is a **pure function over existing peers**
  (`alloc_next_ip` → lowest free host 2..254 in the subnet), reading existing peer
  addresses so `add-client` never collides with or reissues a live address.

---

## 12. State model — `/run`, because the scope is ephemeral (D3)

`/run/wgb/<iface>.env` records everything `down` needs to undo what `up` did:

```
IFACE, WAN_IFACE, SUBNET, DNS, LISTEN_PORT, BURP_PORT, MTU, ENDPOINT,
PROXY_MODE, BLOCK_QUIC, OUTDIR, PRIOR_IP_FORWARD
```

Consequences:
* `up` is **idempotent**: if the state file exists and matches the requested config, it
  reconciles (reloads the table) instead of failing;
* `down` restores `net.ipv4.ip_forward` to `PRIOR_IP_FORWARD`, fixing the web tool's bug;
* `/run` is cleared on reboot, which is the desired semantic for on-site testing.

### 12b. The profile index — `/var/lib/wgb/profile-dirs` (persistent, paths only)

The state file above is about the *tunnel*, and it is gone after a plain `down` or a reboot. Profiles
are different: they are the operator's artifacts and must stay findable, but their directory is
`$OUT_BASE/<timestamp>` and `$OUT_BASE` defaults to `$PWD/out` — so a `qr` from another directory (or
after teardown) used to find nothing.

`up` and `add-client` therefore append the profile directory to a small index under
`/var/lib/wgb/profile-dirs`, and `find_profile_for()` searches session → index (newest first) →
`$OUT_BASE` for a **profile whose private key matches the public key the live config has for that
peer**. The key match is what makes it safe: a leftover profile from a peer that was regenerated
since would otherwise be handed out, and the device would never complete a handshake.

Only directory paths are stored — never key material — so the file is `0644` on purpose, letting an
unprivileged `qr` find the operator's own profiles. `WGB_INDEX_DIR` overrides it (the test suites
point it at their scratch tree).

Log lines are prefixed (`[wgb] ...`), no colour when stdout is not a TTY or `NO_COLOR` is
set.

---

## 13. Gotchas the script must HANDLE, not merely document

1. **Burp bound to 127.0.0.1 silently breaks the redirect.** `redirect to :8083` sends the
   packet to the *incoming interface's own address* (`10.13.37.1:8083`), not to loopback.
   Burp's default first-run bind is 127.0.0.1. `up` must inspect
   `ss -ltnp '( sport = :8083 )'` and refuse/ warn with the fix (bind `0.0.0.0` or
   `10.13.37.1`). This is very likely the #1 real-world "the web generator doesn't work"
   cause.
2. **QUIC/HTTP3 (UDP 443) is invisible to Burp** → `--block-quic` ON by default (D11).
3. **Android Private DNS (DoT, port 853) bypasses the port-53 DNAT entirely.** Post-`up`
   output must say: set Private DNS to *Off* before testing, or you will waste 30 minutes
   blaming DNS when the tunnel is fine.
4. **MTU** — cellular needs < 1420; default 1380 (D13); symptom of getting it wrong is a
   silent TLS handshake hang.
5. **Android CA reality**: user-store CAs are ignored by apps with a
   `networkSecurityConfig` on Android 7+. Most modern apps need a system-store CA
   (root/Magisk) or Frida-based unpinning. `wgb ca` prints this where the tester will see
   it (at 1am, inside the tool's own output).
6. **Leak-proofing on the phone**: closest thing to a kill switch is Android's
   *Always-on VPN* + *Block connections without VPN*; print that reminder after `up`.
7. **IPv6 leak** — handled structurally by `::/0` in client AllowedIPs (D10).
8. **Captive portals** (hotel/venue Wi-Fi) break under a full tunnel; `down` must be fast
   and reliable — another argument for the atomic nft teardown.
9. **Hostile corporate Wi-Fi blocking UDP 51820** — the on-site showstopper. v1 policy:
   `wgb doctor` states the diagnostic plainly ("if the endpoint is unreachable from the
   phone's network, suspect filtered UDP 51820, not your config") and points at the
   fallback options. Do **not** build obfuscation in v1 (§17), but do not design it out.
10. **Same-LAN hairpin**: if the phone and laptop are on the same Wi-Fi, the endpoint must
    be the laptop's LAN IP, and some APs won't hairpin. Implemented as the *default* on a
    NATed host (D17): the advertised endpoint is the main local address, the public
    alternative is printed with what a forward would need, and `doctor` says why.

---

## 14. Test strategy

Runner: `test/run-tests.sh`, pure bash, no bats (D14). Assertions run in subshells so a
failing expectation cannot kill the runner; the runner counts failures and exits non-zero.

Tests that must exist:

| Test | What it proves |
|------|----------------|
| `render_server_conf` == `test/golden/server.conf` | config text is stable |
| `render_client_conf` == `test/golden/client.conf` | ditto, incl. `::/0`, MTU, keepalive |
| `render_nft` == `test/golden/rules.nft` | rule text and **ordering** are stable |
| generated server conf contains **no** `PostUp`/`PostDown` | regression guard for D2 |
| DNS rules precede the catch-all TCP redirect | ordering regression guard |
| `alloc_next_ip` with peers `.2 .3` returns `10.13.37.4` | allocator correctness |
| `alloc_next_ip` with a used `.2` and free `.3` returns `10.13.37.3` | lowest-free, not next-inc |
| `--no-proxy` output omits the redirect line | flag wiring |
| `--allow-quic` output omits the UDP 443 drop | flag wiring |
| `wgb --dry-run` exits 0 as non-root and creates nothing under `/run/wgb` | dry-run is genuinely inert |
| `wgb doctor` exits 0/1 sanely and never mutates | preflight is read-only |
| `wgb up` (no dry-run) at M1 exits 3 | a stub must never look like success |

Fixed test keys (test-only fixtures, generated 2026-10-24, not used for anything real):

```
SERVER_PRIVKEY = pAsgWv6TQfm1hhjN7K3mdmGt1EfT6FtXVIIy+fIjYy4=
SERVER_PUBKEY  = OCmxhidFKnDNIDuq3trOjlRkFZ4LN0zC/3Hp9SyZpEY=
CLIENT_PRIVKEY = VX8e7T2elH3V7o6sUmQWKe/Tl1DAWggg63P8uEJh8qA=
CLIENT_PUBKEY  = f1UGot7KfquzErwHbfrR875sBsLXqE6Inz6O1ub/qIk=
```

**The test that matters most** (written at M2): `up; down; up` on a throwaway VM/netns,
then assert the `nft list table inet wgb` output is byte-identical after the second `up`
— that is the regression test for the entire rule-drift class of bugs.

---

## 15. Milestones

### M1 — skeleton, render layer, dry-run, tests (no root required)
Deliver: `wgb` with arg parsing, defaults, read-only detection
(`detect_wan_iface` via `ip -4 route get 1.1.1.1`, endpoint detect with offline
fallback), `render_*` functions, `--dry-run`, `--print-config`, working `doctor`,
exit-3 stubs for the rest; `test/run-tests.sh` + the three golden fixtures; `LICENSE`,
`.gitignore`, `.github/workflows/ci.yml`, short `README.md`.

Verify:
```
shellcheck -x wgb
./test/run-tests.sh          # all pass
./wgb --dry-run              # exits 0, prints plan, writes nothing
./wgb doctor                 # read-only report
./wgb up                     # exits 3 (not implemented)
```

### M2 — privileged apply path
`up` for real: nft table load, `ip link`/`wg setconf`, state file, ip_forward prior-value
handling, idempotent reconcile; `down` + `status`. Verify the `up;down;up` table-identity
test **on a throwaway VM or network namespace — never on the daily driver**.

### M3 — client management
`add-client` / `remove-client` / `list` / `qr` (+ PNG), `SUDO_USER` chown, qrencode
fallback and adb hint, tests for the allocator.

### M4 — Burp integration & the gotcha set
Port/listen-address check, invisible-proxying + Private DNS + MTU + Always-on-VPN
reminders after `up`, `--block-quic`, `wgb wait` (block until handshake), `wgb ca`.

### M5 — docs & release
Full English README, CI green (shellcheck + tests), tag `v1.0.0`. Nothing in wg-config is
touched (D: wg-config stays as its own project).

---

## 16. Risks / tradeoffs

* **Rule ownership vs. the user's other firewall tooling.** An owned table is clean, but if
  another manager (ufw, firewalld, a hand-rolled nft file) also manipulates forward/nat,
  priorities interact. Mitigation: dedicated table, single hooks, documented priority
  values, and `doctor` reporting other firewall managers it detects.
* **`wg-quick` vs. raw `ip`/`wg`.** `wg-quick` wants `/etc/wireguard/<iface>.conf` and
  brings its own DNS/resolvconf behaviour. Plan: use `wg-quick up/down` for link
  lifecycle only, with PostUp/PostDown empty; revisit if its resolvconf handling
  interferes.
* **Catch-all TCP redirect is inherently blunt** — anything the phone does that Burp
  can't speak (non-HTTP, raw TCP, pinned TLS) lands in Burp and fails. That is the
  intended tradeoff for transparent proxying; `--no-proxy` is the escape hatch.
* **Root requirement** is unavoidable (link, sysctl, nft). Mitigation: hard split so that
  everything testable is testable without root; `doctor`/`--dry-run` never need it.
* **Key handling in bash** — no crypto library; rely on `wg genkey/pubkey` (the real
  implementation). Do not hand-roll anything.

---

## 17. Explicit non-goals for v1

* ssh/VPS/remote provisioning (D3).
* Server-side IPv6 forwarding/NAT66 (v1 kills v6 in the tunnel instead).
* Multi-client batching à la the web tool's `clientCount` — `add-client` covers it.
* A server-side DNS resolver (dnsmasq/unbound) — deferred, §3.2.
* UDP obfuscation / transport fallback (wstunnel, udp2raw) — deferred, §3.3; must not be
  designed out.
* Any change to `~/repo/wg-config`.

---

## 18. Session log (decisions history)

1. User asked for brainstorming on turning the web generator into a shell script.
   Agent read the repo: static HTML + nacl + qrcode, generates server conf with
   NAT/forwarding/DNS-DNAT/TCP-REDIRECT and N client confs with QR codes; README
   documents Burp-intercept use case.
2. Agent proposed: local-first ephemeral scope, owned nft table instead of
   PostUp/PostDown, render/apply split for testability, `add-client` as the key
   functional win, and the gotcha list (§13). Explicit revision from an earlier
   iptables-with-chains idea → nft (D2).
3. User answered the four scoping questions: (a) ephemeral laptop-side, (b) Burp
   transparent proxy is the core use case, (c) script replaces the web page, (d) English.
4. User **rejected deleting/archiving wg-config**: "make a new repo for the new project".
   Locked: repo `wg-burp`, local git only (user pushes), MIT.
5. Environment verified and tooling installed: shellcheck 0.11.0, qrencode 4.1.1;
   sudo runs without an interactive password here (the harness injects it), and piping a
   password to `sudo -S` is blocked by the terminal layer - do not attempt it.
6. User asked for this PLAN.md before any implementation, so that compressed-context
   future sessions keep full project context.

---

## 19. Linux handoff checklist (historical)

This snapshot belongs to the original Linux handoff. For current priorities, see the status and
macOS milestones at the top of this file.

**Needs the operator, not the agent** (the "still NOT verified" list):
1. A real phone: QR import, Private DNS off, Always-on VPN, CA install.
2. Burp actually decrypting TLS through the tunnel.
3. Hour-scale behaviour: rekey, keepalive, a session left up for a day.

**Agent work, in the order I would take it:**
1. **Decide the transport story.** The tool diagnoses filtered UDP 51820 but offers no fallback,
   and a stock phone cannot run a client-side obfuscator (wstunnel/udp2raw need software on the
   device). So the honest deliverable is a decision plus a playbook — hotspot, IPv6, a different
   port, a different network — not a wstunnel integration. §3.3, §17.
2. **Server-side resolver on the tunnel IP** (§3.2), so queries are attributable to the tunnel
   (useful for DNS-exfil observation). Adds dnsmasq/unbound as a dependency.
3. **Identify the listener process** on the proxy port (§3.4), so "something is bound to loopback"
   becomes "Burp (java, pid N) is bound to loopback".
4. **Concurrency**: two simultaneous sessions, and long-duration behaviour, are untested.
5. The repo is **uncommitted** and git identity is unset (§3.1) — the user makes the first commit.

Command name reminder: the product is `wgb`; the repo is `wg-burp`; the old project at
`~/repo/wg-config` is not modified by this work.

---

## 20. Progress log

Newest entry last. Each entry states what was built, the exact commands run, the real
observed result, and any deviation from the plan above. **If this log contradicts an
earlier section, the log wins** — the earlier sections are intent, the log is fact.

### M1 — render layer, doctor, dry-run, tests (2026-10-24) — COMPLETE

Built (all under `~/repo/wg-burp/`):

| Path | What it is |
|------|-----------|
| `wgb` | the product, ~700 lines, executable, shellcheck-clean |
| `test/lib.sh` | shared deterministic render inputs + test keys |
| `test/run-tests.sh` | dependency-free runner, 51 assertions |
| `test/update-golden.sh` | regenerates fixtures (with a warning not to abuse it) |
| `test/golden/{server.conf,client.conf,rules.nft}` | golden fixtures |
| `.shellcheckrc` | `external-sources=true`, `source-path=SCRIPTDIR` |
| `.github/workflows/ci.yml` | shellcheck + test suite |
| `LICENSE` (MIT, patarisac), `README.md`, `.gitignore` | supporting files |

Verification actually run:

```
$ shellcheck -x wgb test/*.sh        -> exit 0, no output (clean)
$ ./test/run-tests.sh                -> "51 passed, 0 failed", exit 0
$ ./wgb up --dry-run --endpoint 192.0.2.10 --wan wlan0   -> exit 0, full plan printed
$ ./wgb doctor                       -> read-only report, mutates nothing
$ ./wgb up --endpoint ... --wan ...  -> exit 3 (stub, as planned)
```

Fixtures were generated from the render layer and then reviewed by hand against the
ruleset in the `mobile-app-traffic-interception` skill reference; rule order, table name
(`inet wgb`), masquerade, QUIC drop and MTU all match.

**Deviations from the plan text (deliberate):**

1. `render_client_conf` takes `(addr, privkey)`, **not** `(name, addr, privkey)` as §6
   said. The client profile is QR-encoded; every byte makes the code denser to photograph,
   so the name lives in the file name instead of a comment in the profile.
2. Extra flags beyond §8: `--wan`, `--subnet`, `--iface`, `--listen-port`, `--timeout`.
   `--endpoint` and `--wan` exist mainly so tests never touch the network.
3. `doctor` resolves the endpoint best-effort and reports; it does not abort on failure
   the way `up` does.
4. `gen_privkey`/`gen_pubkey` emit a marked `DRY-RUN-PLACEHOLDER-*` string when `wg` is
   absent, so `--dry-run` stays useful (and testable) on a box without wireguard-tools.
5. Added `.shellcheckrc` (not in the plan) because the test suite sources `wgb`; without
   `source-path=SCRIPTDIR` shellcheck cannot resolve the cross-file interface.
6. Installed on this box during M1: `shellcheck 0.11.0`, `qrencode 4.1.1` (via apt).
7. Golden fixtures are generated by a committed script rather than hand-written, so they
   cannot drift from the render call signatures; the runner's header warns against
   regenerating to silence a red test.

Environment note confirmed during M1: `sudo` runs without an interactive password in this
development environment; piping a password to `sudo -S` manually is **blocked by the
terminal layer**, which is why privileged input goes through a temp file instead.

### M2 — privileged apply path, verified in a network namespace (2026-10-24) — COMPLETE

Built: `apply_up` / `apply_down`, `cmd_down`, `cmd_status`, and a real integration test.

| Piece | Detail |
|-------|--------|
| `apply_up` | records the prior `ip_forward`, writes client profiles, backs up and replaces the server config, loads the ruleset atomically, enables forwarding, brings the link up, writes `/run/wgb/<iface>.env`, prints the summary and the QR |
| `apply_down` | link down → `nft delete table inet wgb` → restore the recorded `ip_forward` → remove state (or purge config/output with `--purge`) |
| `link_up` | `wg-quick up <conf>` on first run; on a second run `wg syncconf` **without dropping the link**, so a phone mid-session is not kicked |
| rollback | if the ruleset fails to load, forwarding fails, or the link fails, rules and forwarding are rolled back instead of left half-applied |
| `write_atomic` | content on stdin, written to a temp file and `mv`-ed with mode 0600 |
| state | `/run/wgb/<iface>.env`, parsed by `state_get` — **never sourced**, because teardown runs as root (covered by a test that plants `$(touch …)` in a state file) |
| `--print-rules` | new flag: prints the nftables ruleset with no root and no changes |
| `test/integration-netns.sh` | real up/down cycles inside a throwaway namespace: nothing on the host is touched (asserted at the end) |

**The integration test found a bug the dry run and the golden files could not.** The first
generated ruleset did not parse at all:

```
Error: syntax error, unexpected redirect   ->  ip saddr 10.13.37.0/24 tcp redirect to :8083
Error: syntax error, unexpected fwd        ->  chain fwd {
```

Two distinct mistakes: a bare `tcp` expression must be followed by a tcp option, so the
catch-all redirect has to be `meta l4proto tcp redirect to :PORT`; and `fwd` is an nft
reserved word, so it cannot be a chain name. Chains are now `wgb_pre`, `wgb_post`,
`wgb_forward`. **The same bad syntax was in the `mobile-app-traffic-interception` skill
reference, which has been corrected** — it is where the broken ruleset came from.

Verification actually run:

```
$ sudo ./test/integration-netns.sh   -> 40 passed, 0 failed
$ ./test/run-tests.sh                -> 78 passed, 0 failed
$ shellcheck -x wgb test/*.sh        -> exit 0
```

The assertions worth knowing about: the ruleset is **byte-identical** after `up; up`, and
after `up; down; up`; the pre-existing `ip_forward=1` is **restored, not forced to 0**
(the old generator's bug); `nft -c -f` accepts the ruleset; the host has no wgb table, no
config and no state afterwards.

**Deviations from the plan text (deliberate):**

1. `WGB_STATE_DIR`, `WGB_ETC_DIR`, `WGB_OUT_BASE` environment overrides, so the integration
   test can run a real cycle without writing to this host's `/etc`, `/run` or `out/`.
2. `link_up`/`link_down` pass the **config path** to `wg-quick` (which takes the interface
   name from the file name) rather than the bare interface name — same behaviour for the
   default directory, and it is what makes the override above possible.
3. `validate_wg_conf` skips itself when not root: `wg-quick` re-execs itself through `sudo`
   (line 86 of `/usr/bin/wg-quick`), so an unprivileged call fails for the wrong reason.
4. `apply_up` rolls back on failure rather than leaving rules or forwarding enabled.
5. `cmd_status` is deliberately root-tolerant: it degrades to "re-run with sudo" instead of
   failing when it cannot read handshakes.

### M3 — client management (2026-10-24) — COMPLETE

`wgb list`, `wgb add-client NAME`, `wgb remove-client NAME`, `wgb qr NAME [--png]`.

Design points that matter:

* Peers are read back **out of the server config** (`conf_peers`), never from a private
  bookkeeping file: the config is what wg-quick loads, so it is the only source of truth
  that cannot drift. Names come from the `# client: <name>` comments the tool writes.
* `add-client` allocates the lowest free host address above the server address from the
  **live** peer list, so adding a second device never touches the first one's keys or
  address — the web generator regenerated every profile and every key to do this.
* Every config edit is validated with `wg-quick strip` before it is installed, and is
  refused if it has no `[Interface]` section.
* `add-client` pushes the new peer to the running interface with `wg syncconf`, so a new
  phone works immediately instead of at the next reconnect.

**Two more bugs the integration test caught:**

1. **`install_conf` truncated the config.** The helper takes the *complete* replacement
   config on stdin, but `add-client` piped only the new `[Peer]` block — so adding a client
   replaced the entire server config with one peer. Fixed at the call site (`cat "$conf"`
   then the new block) and guarded in the helper (refuse a replacement with no
   `[Interface]` section). Renamed `install_conf_from_stdin` so the contract is in the name.
2. **Every verb but `up` ignored the session's interface.** `wgb up --iface wgm1` followed
   by `wgb add-client tablet` operated on `wgm0`, silently. The state directory is keyed by
   interface, so `adopt_session_iface` now reads the tracked session when `--iface` was not
   given explicitly (`IFACE_SET`).
3. Minor: `die` printed its own exit code as part of the message (`... sudo wgb up 1`).

Verification actually run:

```
$ ./test/run-tests.sh                -> 97 passed, 0 failed
$ sudo ./test/integration-netns.sh   -> 64 passed, 0 failed
$ shellcheck -x wgb test/*.sh        -> exit 0
```

Integration coverage for M3: add a client (address `.3`, profile 0600, live peer count 1→2),
duplicate name refused, remove it (count back to 1, profile gone), unknown client refused,
the original peer undisturbed, and `up` after all that churn still yields exactly one peer.

### M4 — Burp-side integration (2026-10-24) — COMPLETE

`wgb wait [--timeout N]` and `wgb ca`, plus the listener-bind check on `up`/`status`/`doctor`.

* `wait` blocks until a **peer handshake newer than the moment `wait` started** appears, which
  is the honest separation between "the tunnel is up" and "the phone is actually talking to
  me". It warns first if nothing is listening on the UDP port, names the peer that connected,
  and on timeout prints `print_wait_timeout_help`: a playbook ordered by how often each cause
  is real (profile not imported → endpoint unreachable → filtered UDP 51820 → MTU too high →
  Private DNS), followed by the three server-side commands to compare against.
* `ca` prints the CA workflow and the part that fools people: on Android 7+, an app with a
  `networkSecurityConfig` ignores the user certificate store, so a full history of nothing is
  expected even with a perfect tunnel. It also states the verification standard: `http://burp`
  must load on the phone before any empty history means anything.
* `not_implemented` and the exit-code-3 stub path are gone: no stubs remain.

Verification actually run:

```
$ ./test/run-tests.sh                -> 102 passed, 0 failed
$ sudo ./test/integration-netns.sh   -> 74 passed, 0 failed
$ shellcheck -x wgb test/*.sh        -> exit 0
```

### M5 — documentation, CI, and the end-to-end proof (2026-10-24) — COMPLETE

* `README.md` rewritten around the built tool: quick start, command reference, the trap
  table, guarantees, troubleshooting, the three test layers, known limitations.
* `.github/workflows/ci.yml` now installs `nftables`/`wireguard-tools`/`qrencode` and runs
  shellcheck, the unit suite, and **both** integration suites under sudo (each skips itself
  if the runner cannot create namespaces, so CI stays green either way).
* **New `test/integration-tunnel.sh` — the strongest verification in the project.** Two
  namespaces joined by a veth pair: the server namespace runs `wgb up` plus a real listener
  bound to the proxy port; the client namespace imports the *generated* client profile with
  `wg-quick`; then the client requests `http://198.51.100.10/` — an address that exists
  nowhere. The test asserts the server sees the handshake, the listener logs the request, and
  the response body comes back to the client. The decisive assertion is the source address in
  the listener's log: `10.13.37.2` (the tunnel address) and *not* `10.99.0.2` (the veth), which
  proves the traffic went through the tunnel and the redirect rather than around it.

```
$ sudo ./test/integration-tunnel.sh  -> 21 passed, 0 failed
```

This is also the technique now recorded in the `mobile-app-traffic-interception` skill, since
it verifies tunnel + rule order + redirect + listener bind together and needs no phone.

### Final state

| Path | Purpose |
|------|---------|
| `wgb` | the product: one bash script, 2,714 lines, shellcheck-clean |
| `test/run-tests.sh`, `test/lib.sh`, `test/golden/`, `test/update-golden.sh` | unit layer (no root) |
| `test/integration-netns.sh` | real up/down cycles in a namespace |
| `test/integration-tunnel.sh` | client namespace → proxy port, end to end |
| `README.md`, `LICENSE` (MIT, patarisac), `PLAN.md`, `.gitignore`, `.shellcheckrc`, `.github/workflows/ci.yml` | supporting |

Everything a fresh session needs:

```bash
./wgb doctor                          # read-only preflight
./wgb up --dry-run                    # the full plan, no root
./test/run-tests.sh                   # 103 assertions (unit; no root)
sudo ./test/integration-netns.sh      # 74 assertions
sudo ./test/integration-tunnel.sh     # 21 assertions
shellcheck -x wgb test/*.sh           # lint
```

**Open items for the user (deliberately not done by the agent):**

1. Committing and pushing is the user's own step, handled outside this work. The repo has no
   commits and git identity is unset here. **Do not raise it again, do not configure git, and
   do not commit on their behalf.**
2. A real-phone smoke test: the namespaces prove the data path, but a physical phone proves
   the QR import, the CA install and the Android-specific traps.
3. Optional: tag `v1.0.0` once that smoke test passes.

**Known gaps (unchanged from §17, restated so nobody rediscovers them as bugs):** no
obfuscated transport for filtered UDP 51820 (diagnosis only), no IPv6 inside the tunnel
(v6 is dropped server-side), IPv4-only allocation on `/24` subnets, no remote provisioning.

### Post-M5 review — "is it actually done?" uncovered two real defects (2026-10-24)

Triggered by the user asking whether the project was finished. The review deliberately looked
for **paths the tests had never exercised**, not for style, and found two defects plus a set of
unverified areas.

**Defect 1 — a repeat `up` silently invalidated every already-imported client profile.**
Evidence from a probe inside a netns (before/after the second `up`, same arguments):

```
after up + add-client          : conf peers 2, live peers 2, tablet in conf: 1
                                 server key qPzhoB499B1CQDyRrS0/5B6l/shFWjtuOaSzNb+sbWk=
                                 phone key  spP1+v6+Z59TAi0GynqTgPlm5pLjxvaI+aaToDrDDSM=
after a second up, same args   : conf peers 1, live peers 1, tablet in conf: 0
                                 server key qLD4e3Csd3gq1JO/StbA4qR3UPXguiIoIe6PXiT4iWA=
                                 phone key  f8Qr6bn7t0vZLLvHOGGH7fTyTVGMljOeE/A2NPAxDlQ=
```

The second run regenerated the server key, re-keyed the existing client, and deleted the peer
`add-client` had created. That contradicted the README's "idempotent bring-up" claim and broke
the tool's headline advantage over the web generator: an operator re-running `up` after a
network change would find their phone no longer able to connect.

Fix (reuse by default, destroy only on request):
* `conf_interface_privkey` + `conf_peers` feed `build_clients`, which now keeps **every peer
  already in the config** and adds only the names `--clients` requested that are missing;
* `CLIENT_IS_NEW` tracks which clients got a key on this run — profiles are written only for
  those, and a reused client's profile file is left exactly as it is (its private key is not on
  this machine to rewrite);
* the summary marks reused peers and states that a reused profile keeps the
  `--dns`/`--mtu`/`--endpoint` it was built with;
* `--fresh` restores the old behaviour and **warns** that imported profiles will stop working;
* when `OUTDIR` is not recorded (a re-run after `down`), `newest_outdir` adopts the newest
  profile directory so `qr` still finds them.

**Defect 2 — `wait` timed out in the sequence testers actually work in.**
`wait` required a handshake *newer than its own start*. The real order is: scan the QR → the
phone connects → run `wait`. Fixed with a freshness window (`WAIT_FRESH=180`): a handshake from
the last three minutes also counts as proof of a live phone.

**Also fixed or pinned:**
* `die` printed its own exit code as part of the message (`… sudo wgb up 1`).
* The client naming rule (`client` for one client, `client1..clientN` for N>1) is documented in
  `--help`, pinned by unit tests, and when a repeat run keeps a peer that the
  current run did not ask for, `up` names it and prints the `remove-client` line.
* `validate_wg_conf` skips itself when not root (wg-quick re-execs through sudo).
* Test harness: `WGB_TEST_DEBUG=1` dumps the captured output of the last `maybe_run` under a
  failing assertion — it turned a three-round debugging session into one round by showing that
  wg-quick rejected a `DNS` line that had ended up after `[Peer]`.

**Coverage added by the review (paths that had never run):**

| Path | Assertion |
|------|-----------|
| `wait` success | a handshake older than `wait`'s start is accepted, and the peer is named from the config |
| DNS redirect | a query aimed at a resolver the operator did **not** choose arrives at the chosen one, from the tunnel address, never from the veth |
| Rule order | a **TCP** port-53 query reaches the resolver while the proxy port receives nothing — behavioural proof that the DNS rule precedes the catch-all redirect |
| doctor blackhole trap | with a listener on `127.0.0.1:8083`, doctor exits 1 and explains the blackhole |
| `SUDO_USER` | the generated profile is owned by the invoking user, not root |
| default interface | `up` with no `--iface` creates `wgm0` and tears it down again |
| live MTU | `--mtu 1280` reaches the interface, not just the config file |
| reuse semantics | a repeat `up` keeps the server key, the client key and added peers; `--fresh` announces the breakage |
| `--clients 2` | two profiles named `client1`/`client2` and two live peers |
| `qr --png` | a real PNG is written beside the profile (the ANSI path was already exercised by `up`) |
| host safety | `/etc/resolv.conf` is byte-identical after the run (wg-quick hands a `DNS` line to resolvconf) |

Numbers after the review: **121 unit + 117 netns + 37 tunnel = 275 assertions**, all passing,
`shellcheck -x wgb test/*.sh` clean.

**Defect 3 — the operator could not reach their own output.** Found while writing the
explanation of unverified item 3 below to the user, which is the whole point of that item: this
bug exists only on a real host invocation, with a real `SUDO_USER` and a real unprivileged user,
which the namespaces never modelled. Evidence from a namespace run with `SUDO_USER=kali`:

```
session dir : .../out/20261025T120933Z                 owner=root:root   mode=700
              .../out/20261025T120933Z/phone.conf      owner=kali:kali   mode=600
operator can read the profile : DENIED
operator can list the directory: DENIED
```

The file was chowned to the operator; the directory holding it was not. Mode 700 owned by root
means the operator cannot enter the directory at all — so they cannot `adb push` the profile to a
phone, cannot open the QR PNG, and cannot even read the file they own. Every prior test passed
because each one checked the file's owner or the file's mode, never the operator's access.

Fix: `prepare_outdir` chowns the directory it creates (and `out/` itself when the run created
it). New assertions check the operator's actual access with `runuser -u kali -- cat`, not just
ownership. Note for the harness: `mktemp -d` creates its directory `700 root`, so the test also
makes its own temp tree traversable — otherwise the assertion fails on the harness's permissions
instead of the tool's, which is exactly what the first run of these assertions did.

### Config location: decided, implemented, and tested for real (2026-10-24)

Asked whether the server config should live in a local directory instead of `/etc/wireguard`.
Decision: **keep `/etc/wireguard`** (user agreed), for three reasons in order of weight:

1. A root-loaded config in a user-writable path is a local privilege-escalation shape: `wg-quick`
   runs as root and executes what the config says. Note `wg-quick`'s own world-accessibility check
   masks permissions and only tests the world bits, so a user-owned `0700` directory with a
   root-readable config passes its check while staying writable by that user.
2. A directory inside the working tree is one `git add -A` away from committing the server private
   key (the repo ignores only `out/`).
3. Convention: `wg-quick up <iface>`, `wg-quick down <iface>`, `systemctl wg-quick@<iface>`, every
   tutorial and the interception skill all expect `/etc/wireguard/<iface>.conf`. Move it and the
   tunnel becomes a tool-private artifact nothing else can see.

The split the tool already uses is the right one: the **server** config (root secret, loaded by
root) in a system path; the **client** profiles (the operator's artifact) in the working directory
under `out/`, owned by the operator.

Implemented alongside the decision:

* `--config-dir DIR` is now a documented flag (the `WGB_ETC_DIR` override was undocumented), and it
  must be **absolute** — a relative one makes `down`, `list` or `add-client` operate on a different
  file depending on the working directory, which is refused with that reason.
* The state file records `CONF_DIR` and `BACKUPS`, and `adopt_session_iface` adopts the recorded
  **config directory** as well as the interface, so a session started with `--config-dir` can be
  listed, extended and torn down without repeating the flag.
* `backup_config` records each backup it creates, and `down --purge` removes exactly those, only if
  the recorded path still matches our own `.conf.bak-<stamp>` shape. A backup holds the same private
  keys as the config, so leaving it behind after a purge would defeat the purge.
* `/etc/wireguard` is guaranteed to exist (the package ships it `0700 root:root` and `wg-quick`
  never creates it) but `ensure_etc_dir` recreates it `0700` if it is ever missing, instead of
  letting the ambient umask leave it `0755`.

New coverage, including the first tests that touch a real system path:

| Path | Assertion |
|------|-----------|
| **real `/etc/wireguard`, no override** | config lands there, mode `0600`, link created in the namespace; a repeat run backs the previous file up (exactly one backup); `down --purge` removes config *and* backup; the host-untouched group proves no `wgbint*` leftovers |
| `--config-dir` | config lands in the chosen directory; `list` and `down` find it by adopting the recorded directory without the flag |
| relative `--config-dir` | refused as a usage error, with the reason |
| default output directory | `OUT_BASE` defaults to `$PWD/out`; exercised from a scratch cwd so the default is tested without littering the test tree |

Numbers: **127 unit + 139 netns + 37 tunnel = 303 assertions**, all passing, shellcheck clean.

### Post-review hardening: coexisting firewalls and crash safety (2026-10-24)

The two cheap items from the "what's left" list, both implemented and tested.

**Coexisting firewalls (`doctor`).** The old line said "ufw detected - forward/nat interaction is
possible", which is not actionable. The hazard is specific: an nft `accept` is **not terminal
across base chains**, so a DROP policy in another table hooked at `forward` drops tunnel traffic no
matter what this tool installs. `doctor` now lists every other table with a `forward` hook and
reports ufw/firewalld state with the consequence and the fix ("allow the subnet there too").
Tested against a real competing table:

```
nft add table inet otherfw
nft 'add chain inet otherfw otherfw_forward { type filter hook forward priority filter; policy drop; }'
  -> doctor: WARN other tables also hook forward: inet otherfw
             an nft accept is NOT terminal across base chains, so a DROP policy there
             drops tunnel traffic regardless of what this tool installs...
```

**Crash safety.** `apply_up` wrote the state file *last*, so a kill between enabling forwarding and
finishing left `ip_forward=1` with nothing recording the value to put back. The state is now written
**before any mutation**, and written again after `backup_config` so `--purge` knows which backups to
remove. Tested by `SIGKILL`-ing a bring-up the moment the state file appears, then requiring `down`
to remove the rules and interface, restore forwarding to the pre-crash value, and clear the state —
all asserted, including that the bring-up really was still running when it was killed.

**Two bugs found while doing this — both by the new assertions, both fixed:**

1. `other_forward_chains` ended in `grep -v`, which exits 1 when it filters everything out. So
   `others="$(other_forward_chains)"` returned non-zero and **`set -e` aborted `doctor` mid-report**.
   The loopback FAIL assertion still passed, because an exit-code-only assertion cannot distinguish
   "failed correctly" from "died early" — that assertion now also requires doctor's closing line.
2. Writing the state *before* the backup meant the backup path was never recorded, so `down --purge`
   left key material in `/etc/wireguard`. The real-path group then tripped over its own leftovers
   from the previous failing run; it now clears and reports them first, so an interrupted run cannot
   skew its counts.

Numbers: **129 unit + 152 netns + 37 tunnel = 318 assertions**, all passing, shellcheck clean.

### Real host run, with a real sudo (2026-10-24) — closes unverified item 3

Ran `sudo ./wgb up` on this machine for real (default paths, `SUDO_USER` set by sudo), verified
every artifact, then `sudo ./wgb down --purge`. Pre-flight was recorded first so restoration could
be proved, not assumed.

**Before:** `/etc/wireguard` empty, `ip_forward=0`, no nft tables, no `wgm0`, UDP 51820 free,
no `/run/wgb`, no `out/`. (`tun0`, the operator's own VPN, was up.)

**Verified after `up`** (exit 0):

| Artifact | Result |
|----------|--------|
| `/etc/wireguard/wgm0.conf` | created, `0600 root`, comment intact, **zero** `PostUp`/`PostDown` |
| `/run/wgb/wgm0.env` | created, `0600`, records `CONF_DIR=/etc/wireguard`, `BACKUPS=`, `PRIOR_IP_FORWARD=0`, `OUTDIR` |
| `wgm0` interface | up, `10.13.37.1/24`, `mtu 1380` |
| nft | `table inet wgb` with DNS DNAT before the catch-all redirect, masquerade on `eth0`, QUIC drop, accepts (nft canonicalises `dnat to` as `dnat ip to` — same rule) |
| `ip_forward` | `1` |
| client profile | `out/<ts>/phone.conf` and its **directory** both owned by `kali` (`600`/`700`), and readable by the operator as themselves — the ownership defect is fixed under a real sudo |
| profile validity | `wg-quick strip` accepts it |
| listener | UDP 51820 bound on `0.0.0.0` and `[::]`; the tool correctly warned that nothing was on 8083 |
| QR | rendered in the ANSI QR to the terminal |

**After `down --purge`:** `ip_forward` back to `0`, zero nft tables, `wgm0` gone, UDP 51820 free,
`/etc/wireguard` empty again, `/run/wgb` gone, `out/` gone, `tun0` untouched, repo tree clean
(the tool added `removed empty ~/repo/wg-burp/out` to its own output).

**Two teardown gaps this run exposed — the last bugs found in the project, both fixed:**

1. `down` left the rendered ruleset at `/run/wgb/<iface>.nft`. Nothing tracked it: `load_rules`
  wrote it and no path removed it. A reboot would have hidden this (tmpfs); the run did not.
2. `down --purge` left the output base directory behind, empty.

Both are now removed (`rm` the ruleset; `rmdir` the state directory and the base once empty), and
the recursion guard was rewritten: it used to require the literal component `/out/`, which silently
**skipped** removing the profiles for any other base name — turning the README's `--purge` promise
into a false one. It now requires the recorded directory to be a timestamped name directly under the
configured base, warns when it refuses, and removes the base only when it just emptied it. 8 new
assertions cover plain teardown, purge, and a base that must survive because it holds something else.

Numbers: **129 unit + 171 netns + 37 tunnel = 337 assertions**, all passing, shellcheck clean.

### Adversarial review: every remaining flaw found, fixed and covered (2026-10-25)

A read-it-all-and-try-to-break-it pass over the whole tool, then each finding fixed with an
assertion. Ten findings, in order of consequence:

| # | Flaw | What it did | Now |
|---|------|-------------|-----|
| 1 | `qr --png` honoured the umask | wrote the **private key** as a world-readable `644` PNG next to the profile in a `700` dir | `chmod 600` before chown; asserted real-host (`600 kali`) |
| 2 | `assert` the config dir is root-only was only in the help text | nothing stopped `--config-dir /tmp` (1777) for a config root loads by name | `assert_conf_dir_safe` refuses group/other-writable dirs before writing; asserted, and verified on the real host against `/tmp` |
| 3 | `--wan` / `--endpoint` were unvalidated | a quote landed in the nft ruleset as syntax; a newline landed in the profile **shipped to the phone** | `is_iface_name` / `is_host` at validation time; asserted with both payloads |
| 4 | Conf-dir adoption was coupled to `--iface` | `down --iface X --purge` after `up --config-dir Y` deleted a default-path config and left the real key material in `Y` | adoption moved out of the `IFACE_SET == 0` branch; asserted |
| 5 | The tightened purge guard compared against `$PWD/out` | `--purge` from another directory would skip the profiles entirely | `OUT_BASE` recorded in state and adopted when the env did not pin it; asserted by purging from a different cwd |
| 6 | Key-bearing temp files were written before `chmod` | the profile/state/config were briefly created with the ambient umask | `umask 077` for every such write |
| 7 | `remove-client` wrote `$conf.removing.$$` | a second file holding the **server private key**, left on disk if interrupted | the filtered config is piped straight into the installer; no copy |
| 8 | `load_rules` deleted the live table before parsing the new one | a ruleset that failed to parse cost a running session its interception rules | `nft -c -f` first, then delete, then load |
| 9 | `wait` never validated `--timeout` | `wait --timeout abc` read the word as an unset variable → "wait 0 seconds" | validated in `cmd_wait`; asserted |
| 10 | Leading-zero octets hit a bash arithmetic error | `--dns 08.8.8.8` printed `value too great for base` before failing | octets with leading zeros rejected cleanly; asserted, including that the bash error is gone |

Plus two robustness gaps in the same class as the earlier ones: the state directory is now created
`700` before the session record is written (not fixed later in `load_rules`), and values read out
of the state file are shape-checked before they build paths (`IFACE` must be a plausible interface
name, adopted paths must be absolute). `down` also now names the config backups it deliberately
leaves behind, and a purge says when it removes the config.

Findings 4, 6-10 and the two robustness gaps were pre-existing. Finding 1 was pre-existing.
Findings 2, 3 and 5 are the direct consequences of the earlier `--purge` guard tightening: #5 is
the case the tightening *introduced*, which is why it was caught in the same pass.

**Known limitations left, deliberately** (all fail safe, none delete the wrong thing):

- A config directory whose path contains a space: backups are recorded space-separated, so the purge
  warns "not removing unexpected backup path" and leaves that one backup rather than guessing.
- A purge cannot remove an earlier session's backups or profiles once its state is gone — the state
  is what made them findable, and inferring them would mean globbing paths to `rm -rf`.
- Two simultaneous sessions on different interfaces: the tool warns and picks the newest.

The tunnel-port family (`--listen-port`, `--burp-port`, `--mtu`, `--clients`, `--subnet`, `--iface`)
was already validated and is unchanged.

### The advertised endpoint: behind NAT, and moving (2026-10-29)

Found while looking for the next thing worth building, with the machine as the witness: this host
holds only `192.168.1.50/24`, while `detect_public_ip` returned `203.0.113.9`. The tool wrote
that address into the phone's profile as the endpoint and reported success. Nothing in the tunnel is
wrong — the phone simply dials a NAT that has no reason to forward UDP 51820 to us, and `wait`
eventually prints generic advice. That is precisely the on-site hour the tool exists to save.

Implemented:

* `endpoint_behind_nat()` — true only when the endpoint is an IPv4 literal this host does **not**
  hold (a hostname cannot be judged that way and is never claimed). `local_ipv4_all()`,
  `route_src_ipv4()` and `nat_target_hint()` support it.
* `doctor` (ROUTING), `up` (stderr) and the `--dry-run` plan all now say it in one sentence and name
  the address a port forward would have to target, including the CGNAT case where no forward can
  exist, and the LAN-address fallback (`--endpoint <lan-ip>` for a phone on the same network).
* A moved endpoint is no longer silent: `up` compares the freshly resolved endpoint with the one the
  live session recorded and warns that profiles already scanned onto a device keep dialling the old
  address (`re-send it: wgb qr <name>`). The public address here changed twice in one session, so
  this is not hypothetical.
* Print modes (`--print-rules`, `--print-config`) stay silent: their stdout is the artifact. This
  was found by the netns ruleset test, which writes combined output to a file and feeds it to
  `nft -f` — the warning landed in the ruleset.

**And it exposed a real bug of its own.** `up; up; down` left `ip_forward=1` for good: the repeat
run re-read the global the tool had itself set, recorded "1" as the prior value, and teardown
"restored" 1. Fixed by adopting the recorded prior value while the tool's own link is still up
(`up; up; down` now ends at 0, verified on this host, and pinned by a netns group that starts from a
value the tool did not choose).

Numbers: **152 unit + 207 netns + 37 tunnel = 396 assertions**, all passing, shellcheck clean.

### Endpoint policy: advertise an address this host holds (2026-10-29)

The user's question pinned it: *"why is the client config generated points to the wrong ip server
endpoint?"* It pointed at `203.0.113.9` — the NAT's address — because `resolve_endpoint` preferred
the public IP unconditionally and used the host's own LAN address only as a fallback when that
lookup failed. Right for a phone on cellular *if* something forwards the port; wrong everywhere else.

Per the user's decision (now D17), the policy is:

1. `--endpoint` always wins.
2. The detected public address **only if this host holds it** (then a cellular phone reaches it
   directly).
3. Otherwise the host's **main local address** — the default-route source, i.e. the LAN/WLAN
   address — with the public alternative printed and what it would need:

```
  endpoint       192.168.1.50:51820  (main local address: this host is behind NAT)
                 a phone on this network connects to it. Not reachable from cellular
                 until UDP 51820 is forwarded to 192.168.1.50 upstream;
                 then use:  --endpoint 203.0.113.7
```

`up` says the same in two lines, `doctor` reports the reasoning, and the tunnel's own address is
never advertised (a default route through `wgm0` would otherwise offer it). This is the policy
§13.10 already described; until now the implementation did not follow it.

Tests: the decision is covered deterministically by stubbing both lookups inside subshells —
behind-NAT, host-holds-the-address, no default route, a route source inside the tunnel subnet,
nothing to advertise, and `--endpoint` winning. The netns suite adds the end-to-end property: with
no `--endpoint` at all, the recorded endpoint must be an address the namespace holds and the client
profile must dial exactly that. Verified on this host: the profile now reads
`Endpoint = 192.168.1.50:51820`.

One trap worth recording: the stubs collided with `choose_default_endpoint`'s own `local pub`,
because bash scoping is dynamic — the stub read the callee's unset local and `set -u` failed it.
Test helpers need names that cannot collide.

Numbers: **159 unit + 214 netns + 37 tunnel = 410 assertions**, all passing, shellcheck clean.

### `qr` after a teardown: the documented promise was false (2026-10-29)

The user ran `sudo ./wgb qr phone` and got *"no session is tracked - bring the tunnel up first"*. On
that machine there was genuinely no session (my verification runs end with `down --purge`, which
removes config, state, profiles and `out/`). But the message exposed a real defect under it: a plain
`down` removes the state file and **keeps** the profiles — `up` says so out loud ("a plain teardown
keeps the profiles. Reprint any of them with: wgb qr <name>") — and `qr` looked *only* in the state,
so it refused to print a profile sitting right there on disk. The guarantee was documented, printed,
and half-tested.

Fixed:

* `find_profile_dir()` — the recorded session directory, or the newest one under the output base —
  used by `qr` and by `list`'s "profiles in:" line. A plain teardown now really does keep the
  profiles reprintable, and `qr` says which directory it fell back to.
* The not-found message names the directory it looked in and how to recover (`-- or run this from
  the directory you started the session in`): the output base defaults to `$PWD/out`, so a `qr` from
  another directory is a real way to land here.
* A wrong name now lists the profiles that DO exist in that directory
  (`profiles from this session: phone`) instead of only reporting the miss.

Tests: unit — a kept profile is found with no state at all, an unknown name lists what exists, and
the no-session/no-profiles case names the directory it searched. Netns — the promise end to end:
`up`, plain `down`, then `qr phone` must still print. Verified on this host, including the failure
path from a directory with no profiles (`/tmp/out holds no profile directory`).

Numbers: **165 unit + 216 netns + 37 tunnel = 418 assertions**, all passing, shellcheck clean.

### Profiles must stay findable, and a lost one must be reported (2026-10-29)

User report from his own machine: `sudo ./wgb up` succeeded but said *"peer reused phone ... (profile
left alone)"*, then `sudo ./wgb qr phone` failed with *"no profiles found: no session is tracked and
/home/patsac/repo/wg-burp/out holds no profile directory"*. Three real defects behind that:

1. **Profiles were only findable from the directory the session was started in.** `qr` looked in the
   state (which a plain `down` deletes, and which held no directory at all here) and then in
   `$PWD/out`. A session started elsewhere, or queried elsewhere, found nothing while the profile sat
   on disk. Fixed with the persistent index (§12b) plus the key-aware search.
2. **A peer whose profile is gone was treated as "nothing to do".** `up` said *"every peer was
   reused ... a device that already imported one needs nothing"* — but a peer's private key exists
   ONLY in its profile file, so with the file gone the device can never be imported again, and the
   tool said nothing. `up` now names those peers and gives the remedy (`remove-client <name> &&
   add-client <name>`, or `up --fresh`).
3. **A name match could hand out a stale profile.** Searching by name across remembered directories
   finds an older `phone.conf` whose key no longer matches the config's peer (the tests caught this:
   the warning refused to fire because an earlier session's profile "satisfied" the lookup). Printing
   that profile would import a device that can never complete a handshake. `find_profile_for()` now
   requires the profile's private key to derive the public key the live config has for that peer, and
   `qr`'s refusal distinguishes "peer exists, key not here" (with the remedy) from "no such name"
   (listing the names that do exist).

Also fixed while reproducing it: `up` claimed *"existing ones are in <dir>"* for a recorded directory
that no longer existed; the searched-dirs list repeated itself; and `test/integration-tunnel.sh` was
writing to the real `/var/lib/wgb` (all three suites now redirect `WGB_INDEX_DIR`).

One bash trap worth recording: `newest_outdir` prints no trailing newline, and a `while read` loop
**drops a final line that has none** — the function that listed profile names silently returned
nothing until a trailing `printf '\n'` was added. That is why the "profiles that do exist" hint did
not appear.

Numbers: **175 unit + 228 netns + 37 tunnel = 440 assertions**, all passing, shellcheck clean.

### The `add-client` profile was unusable (2026-10-29)

User report from his own phone: *"when i scan the qr code, it said 'syntax error in peer'"*. That is
the WireGuard app's message for a peer block with an empty or malformed field, and it was ours:
`add-client` wrote

```
[Peer]
PublicKey =
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = :51820
```

`SERVER_PUBKEY` and `ENDPOINT` are resolved inside `cmd_up`, and `cmd_add_client` rendered the profile
without ever resolving them — so the QRs it printed could never be imported. A second defect came out
of the same omission: with `SUBNET` also unset, `add-client` allocated the new peer from the *default*
subnet even when the session had been started with `--subnet`, so the peer and the profile disagreed
with the tunnel.

Fixed:

* `load_client_render_context()` — every writing path now adopts the session's recorded values
  (`ENDPOINT`, `LISTEN_PORT`, `DNS`, `MTU`, `SUBNET`) and derives `SERVER_PUBKEY` from the config the
  client will actually talk to, falling back to the same endpoint policy `up` uses.
* `client_profile_defect()` — a content check before writing: a profile whose `[Peer]` has no usable
  `PublicKey` or `Endpoint` is refused with the reason instead of being written. This is the guard
  `wg-quick strip` cannot provide (it accepts both malformed fields; they are syntactically fine).

Why the tests missed it for so long: the netns suite asserted `add-client`'s **side effects** (exit
code, allocated address, peer count, file mode 0600) and never the file's **content**, while the
golden fixtures render `render_client_conf` with the globals set by hand. The new assertions compare
the profile's `PublicKey` against `wg show <iface> public-key` and its `Endpoint` against the session's
recorded endpoint, plus a group proving the peer is allocated inside the session's own subnet.

Numbers: **179 unit + 236 netns + 37 tunnel = 452 assertions**, all passing, shellcheck clean.

### The ruleset now counts: on-site diagnosis without tcpdump (2026-10-29)

User report: *"i cannot access anything beside the host ip (wlan) port burp. i still can access the
burp landing page."* That narrows to two causes — Burp refusing to forward what it receives, or the
TCP redirect never firing — and neither is visible from outside the box. Every rule now carries a
`counter`, so `sudo nft list table inet wgb` answers "which rule matched?" with no extra tooling:

```
ip saddr 10.13.37.0/24 meta l4proto tcp counter packets 12 bytes 720 redirect to :8083
```

How to read it while the phone is connected:

* **redirect at 0** → the phone's TCP never reached the tunnel's prerouting: client-side `AllowedIPs`,
  or another VPN app on the phone holding the tunnel.
* **redirect non-zero and Burp silent** → the traffic arrives and Burp drops it: its listener is not in
  transparent mode ("Support invisible proxying"), or a "Redirect to host/port" is set on it.
* **`iifname wgm0 accept` non-zero with masquerade at 0** → forwarded traffic is leaving without NAT
  (wrong `--wan`), so replies never come back.
* **DNS DNAT non-zero but the phone cannot resolve** → DoT/Private DNS on the device bypasses it.

Tests: the end-to-end suite now asserts the redirect rule's counter is **non-zero** after the client's
request — a rule that carries a counter is not the same as a counter that counts. The netns suite
strips counter stats before comparing snapshots (`ns_snapshot`), because those numbers change as
traffic flows and those assertions are about rule identity, not traffic.

Numbers: **179 unit + 236 netns + 38 tunnel = 453 assertions**, all passing, shellcheck clean.

### The other firewall's DROP policy: named, with the remedy (2026-10-29)

Follow-up to the two reports above, and the counters were the witness. On the user's machine: `ufw` is
active, and libvirt, docker and Tailscale all add chains to the same `ip filter` table, whose
forward-hook chain has `policy drop`. Their ruleset said it in two lines:

```
iifname "wgm0" counter packets 691 bytes 46986 accept        <- 691 packets entered forwarding
ip saddr 10.13.37.0/24 oifname "wlan0" counter packets 0 masquerade   <- not one reached NAT
```

Accepted by us, dropped after us, never NATed: an `accept` in our base chain cannot override a `DROP`
in another. The tool *had* a warning for this ("an nft accept is NOT terminal across base chains") but
left the operator to translate it into a command, and `up` — the moment it matters — said nothing.

* `forward_drop_chains()` — the other tables whose forward-hook chain is `policy drop`, as opposed to
  `other_forward_chains()` which lists all of them.
* `report_forward_drops()` — one implementation, used by both `doctor` and `up`: names the table(s),
  states the consequence ("anything NOT sent to the proxy, DNS included, never reaches the
  internet"), and prints the fix — `sudo ufw route allow from <subnet>` when ufw is installed.
* `up` reports it at bring-up, where the operator is standing when the phone fails to load a page.

Tests: the netns DROP-chain group now asserts the policy wording, the remedy line, and that a repeat
`up` warns. Verified on this host by adding a temporary table with a DROP forward chain: both `up` and
`doctor` name it and give the command. (That experiment also reproduced nft rejecting `fwd` as a chain
name — the reserved word the tool sidesteps by using `wgb_forward`.)

Numbers: **179 unit + 241 netns + 38 tunnel = 458 assertions**, all passing, shellcheck clean.

### `doctor` quotes ufw instead of paraphrasing it (2026-10-29)

The user, after being told ufw was dropping the forwarded traffic: *"i think my ufw is already allow
all incoming req"*. That is the trap in one sentence — **incoming rules do not govern forwarded
traffic**. Packets from the tunnel are routed (wgm0 → wlan0) and never traverse INPUT; ufw decides
them with a third policy of its own, which reads `disabled (routed)` by default on Debian-family
systems. The old wording ("if its DEFAULT_FORWARD_POLICY is DROP...") invited exactly this reading, so
`doctor` now prints ufw's own default line and names the consequence:

```
WARN ufw is active. Its incoming rules do NOT apply to forwarded traffic, so "allow all incoming"
     does not cover the tunnel. ufw says:
       Default: deny (incoming), allow (outgoing), disabled (routed)
     ... Fix:
       sudo ufw route allow from 10.13.37.0/24
```

Tested in the netns suite with a stand-in `ufw` on `PATH` (this host has no ufw), asserting the
quoted line, the incoming-rules sentence, and the command.

Numbers: **179 unit + 244 netns + 38 tunnel = 461 assertions**, all passing, shellcheck clean.

### The tool now fixes the ufw drop itself — and reverts it (2026-10-29)

User's suggestion after the diagnosis: *"can it just set in the wgb script when up the profile and
don't forget to revert when down ing the profile. it can be like that right?"* Yes, and it should be:
the tool already changes a config file and `ip_forward` and records both for teardown, so an allowance
in ufw is the same shape of thing.

* `fix_forward_drop()` — runs at the end of `up` when another forward chain has `policy drop`. If ufw
  is installed, active and owns the policy, it runs `ufw route allow from <subnet>` (ufw's own
  command, so the rule survives `ufw reload`), and records `FIREWALL_FIX=ufw-route:<subnet>` in the
  state. If the subnet is already allowed, it says so and records nothing, so teardown cannot remove a
  rule the operator added.
* `undo_forward_drop_fix()` — `down` removes exactly the recorded rule and reports it. Anything not
  recorded is never touched, and an unrecognised record is reported instead of acted on.
* `--no-fix-firewall` keeps the old advisory-only behaviour. For non-ufw firewalls the tool still
  refuses to guess at another product's rule syntax and says what to allow instead.
* The plan (`--dry-run`) shows the rule it would add and that `down` removes it.

Tests run against a stateful stand-in `test/helpers/fake-ufw` (this host has no ufw): it records every
invocation and keeps a rule list, so the suite asserts the add happens once, that it is recorded, that
`down` deletes it, that `--no-fix-firewall` touches nothing, and that a pre-existing rule is neither
duplicated nor removed. Verified on this host with a temporary DROP table: `up` added the rule and
recorded it, `down` removed it, and the fake's call log shows exactly
`status`, `status`, `route allow from 10.13.37.0/24`, `route delete allow from 10.13.37.0/24` (the
fake was later corrected to ufw's real CLI shape — see the live-ufw section below, where the earlier
`delete route allow ...` form turned out to be invalid).

Numbers: **179 unit + 263 netns + 38 tunnel = 480 assertions**, all passing, shellcheck clean.

### What happens without ufw — and the two bugs that question found (2026-10-29)

User's question: *"do you check what will happen if the user doesn't have ufw installed or doesn't
enable the ufw?"* Checking it properly found two real bugs, both of which would have reproduced the
original hour-long debugging session while the tool reported success.

1. **`grep -q active` matched "Status: inactive".** ufw's status line contains the word `active` inside
   `inactive`, so a switched-off ufw was read as an active one: `up` ran `ufw route allow`, and told
   the operator the drop was fixed, on a host where ufw was not even in play. Now one helper,
   `ufw_is_active()`, matches the whole line (`^Status:[[:space:]]+active[[:space:]]*$`) and is the
   only place that question is asked.
2. **An active ufw was credited with fixing another product's DROP policy.** A `policy drop` in
   docker's, libvirt's or a hand-rolled table cannot be lifted by a ufw route rule - ufw's chains are
   not what drops the packet. `up` added the rule anyway and logged "allowed forwarded traffic ... in
   ufw", so the operator would be sent back to the top of the same hunt. `ufw_owns_drop()` now
   requires that one of the dropping tables actually contains ufw's own `ufw-*` chains before ufw is
   used at all.

The five cases, each verified on this host with a temporary table and the stand-in ufw:

| host state | what `up` does |
|---|---|
| no ufw, foreign table drops | names the table and the subnet; changes nothing |
| ufw installed, not active | says ufw is not the cause; names the table; changes nothing |
| ufw active, foreign table drops | says a ufw route rule would not help; names the owner (docker/libvirt/Tailscale) with the command that product documents; changes nothing |
| ufw active, its own chain drops | adds `ufw route allow`, records it, `down` removes exactly it |
| nothing drops forwarded traffic | silent |

`forward_drop_owner_hint()` is what makes case three actionable: it reads the dropping table and, when
the chain names give the owner away, prints the sanctioned command for it (docker: `iptables -I
DOCKER-USER -s <subnet> -j ACCEPT`). When they do not, it names the table and nothing more - no
guessing at another product's rule syntax, and never a change the tool cannot undo.

Numbers: **179 unit + 286 netns + 38 tunnel = 503 assertions**, all passing, shellcheck clean.

### Second full audit — five defects, all fixed (2026-10-29)

User: *"please recheck the whole code & make sure no errors. make no mistake."*

Method: read all 2,561 lines again, `shellcheck` down to `-S style` (now zero findings), `bash -n`, greps
for `eval`/`source`/unquoted paths/backticks-in-code, and — because the newest code talks to ufw and
this host has no ufw — **downloading the ufw package without installing it** (`apt-get download ufw` +
`dpkg-deb -x`) to read its own argument parser and status renderer. That last step is what found the
first two bugs; reasoning from memory would have shipped both.

1. **`ufw delete route allow from X` is not a valid command.** ufw re-inserts `rule` after a leading
   rule command (frontend.py: `argv.insert(idx, 'rule')`), so that line is parsed as `rule delete
   route allow from X` and rejected as "Invalid syntax". `down` used exactly that form, and printed it
   as the manual remediation too. The valid form, from ufw's own command table
   (`'route-delete': "route delete RULE|NUM"`), is **`ufw route delete allow from X`**.
2. **`ufw_route_listed` matched an incoming allow.** It grepped only for the subnet, but ufw renders a
   routed allow as `ALLOW FWD <src>` and an incoming one as `ALLOW <src>`. So on a host whose ufw has
   `ufw allow from 10.13.37.0/24` — literally the operator's "my ufw already allows all incoming" —
   `up` skipped the route rule and reported the drop as already fixed while the phone stayed dead. Now
   only a line containing `ALLOW FWD` counts.
3. **The same substring bug in `doctor`**: `case "$(ufw status | head -1)" in *active*)` also matched
   `Status: inactive`. Both call sites now use the one `ufw_is_active()` helper.
4. **A repeat `up` erased what the first one recorded.** `apply_up` rewrites the state file wholesale,
   so the second run blanked `FIREWALL_FIX` (its rule was already in place, so it set nothing) and the
   earlier `BACKUPS` — `down` then left the ufw rule behind and `--purge` left key material behind,
   while reporting a clean teardown. `apply_up` now adopts the recorded `BACKUPS`/`FIREWALL_FIX` before
   its first write, and `fix_forward_drop` recognises its own rule ("still in place").
5. **`add-client` with no session state used the default subnet.** After a plain `down` (or a reboot)
   the state is gone, so a new peer was allocated from `10.13.37.0/24` even when the config's peers
   lived in another subnet — a profile that cannot work. The subnet and MTU now come from the loaded
   config itself, validated the same way `up` validates flags.

Four regression tests were added (incoming-allow vs routed-allow; repeat-`up` record survival for both
the firewall fix and the backups; the `route delete` form; config-derived subnet/MTU for `add-client`),
and the stand-in ufw was corrected to ufw's real CLI shape.

Verified on this host with a ufw-shaped DROP table, a real sudo cycle: `route allow` once, the repeat
says "still in place" and adds nothing, `route delete` (valid form) on teardown, backups purged, host
restored.

Numbers: **179 unit + 309 netns + 38 tunnel = 526 assertions**, all passing, shellcheck clean.

### The ufw interaction, run against a LIVE ufw — and purged again (2026-10-29)

The user authorised it: *"you can install and use ufw for testing. but don't forget to clean up & purge
it after."* This closed the one caveat that had been standing under the firewall feature — every claim
about ufw had been verified against its source and a stand-in, never against the real thing.

Installed `ufw 0.36.2-10` (the same series Debian/Kali ships, `DEFAULT_FORWARD_POLICY="DROP"`, i.e. the
condition on the user's own laptop). No SSH session was active; SSH and the local subnet were allowed
before `ufw --force enable` anyway, so enabling a default-deny firewall could not lock anyone out.

What the live run proved, in its own words:

* **The old delete form is invalid** — `ufw delete route allow from 10.13.37.0/24` → `ERROR: Invalid
  syntax`, exit 1, and ufw's usage block lists `route delete RULE|NUM`. `ufw route delete allow from
  10.13.37.0/24` → `Rule deleted`, exit 0. Defect 1 of the audit, confirmed against the real binary.
* **The routing/incoming distinction is real and load-bearing** — with `ufw allow from 10.13.37.0/24`
  present (INCOMING), `ufw status` shows `Anywhere ALLOW 10.13.37.0/24`, and after a routed allow it
  shows a separate `Anywhere ALLOW FWD 10.13.37.0/24`. The pre-fix code matched on the subnet alone
  and would have skipped the fix.
* **`doctor` quotes ufw verbatim** — `Default: deny (incoming), allow (outgoing), disabled (routed)`,
  exactly the line the code prints.
* **The whole lifecycle, live:** with only an incoming allow present, `up` ADDED the routed rule and
  recorded `FIREWALL_FIX=ufw-route:10.13.37.0/24`; a repeat `up` said the rule "is still in place" and
  left exactly one routed rule; `down --purge` removed its own rule (0 routed rules left) while leaving
  the operator's incoming allow and the safety rules untouched, and removed the config, the backup and
  the empty output base.

Cleanup (also live): rule deleted by hand, `ufw --force disable`, `ufw --force reset`, then
`apt-get purge -y ufw`. Purge alone was NOT enough — this is the part worth remembering: dpkg cannot
know about files ufw created *after* installation, so `/etc/ufw/*.rules.<timestamp>` backups,
`/etc/ufw/applications.d` and `/var/lib/ufw` survived and had to be removed by hand, and disabling
leaves ufw's (now empty) `ip filter` / `ip6 filter` tables in the kernel — two tables that did not
exist before the install. All removed; `/usr/sbin/ufw`, the package, the systemd unit and every
`*ufw*` file are gone, `nft list tables` is 0 again, and the host is byte-equivalent to its
pre-install state (`ip_forward=0`, no `wgm0`, `/etc/wireguard` empty, no `/run/wgb`, no
`/var/lib/wgb`, no `out/`).

Numbers unchanged: **179 unit + 309 netns + 38 tunnel = 526 assertions**, all passing after the
cleanup, shellcheck clean.

### A reboot before `down`: what survives, and the hole it exposed (2026-10-29)

User: *"if the machine rebooted before the user down the wgb, will the config wiped out?"* Answered by
simulating the post-reboot condition faithfully (state gone, our kernel objects gone, disk intact):

| after a reboot | state |
|---|---|
| `/etc/wireguard/<iface>.conf` | **survives** — the tunnel can be brought back up with the keys and peers intact |
| client profiles, `out/<stamp>/`, the profile index | **survive** (`wgb qr` still works) |
| session state `/run/wgb/<iface>.env` | gone — `/run` is tmpfs |
| our nft table, the interface | gone with the kernel |
| **the ufw route rule this tool added** | **survives** — ufw rules are persistent by design |
| config backups in `/etc/wireguard/*.bak-*` | **survive** — and they hold the same private keys |

That last pair was a real defect: the record of those changes lived only in `/run`, so after a reboot
`down` reported "nothing to tear down", left the ufw rule installed, and could never remove it again —
and a later `up` correctly treated it as somebody else's rule ("already allowed in ufw - leaving it as
it is"), so nothing ever claimed it back. The tool's promise ("down reverts exactly what it changed")
silently stopped holding at the one moment it matters most.

Fix: the record of changes made OUTSIDE the tool's own objects moved to durable storage —
`/var/lib/wgb/undo-log` (next to the profile index; paths and rule specs only, never key material,
mode 644). `up` records `ufw-route:<subnet>` and `backup:<path>` there as well as in the session state;
`down` reverts whatever is recorded, including what an earlier session left behind; `--purge` removes
backups from either record; `doctor` reports anything still pending; and an `up` that finds our own
rule with a durable record adopts it ("this one adopts it and removes it on `down`") instead of
disowning it.

Verified live against a real ufw (installed for the test, then purged again): `up` added the rule and
wrote `ufw-route:10.13.37.0/24` to the undo log (mode 644); a simulated reboot wiped `/run`, the table
and the interface while ufw kept listing `Anywhere ALLOW FWD 10.13.37.0/24`; `wgb down` then removed
exactly that rule and cleared the record, leaving `/etc/wireguard/wgm0.conf` untouched; `doctor`
reported nothing pending; `down --purge` removed the config.

Numbers: **179 unit + 327 netns + 38 tunnel = 544 assertions**, all passing, shellcheck clean.

### "Plenty of SSL errors" was IPv6 in a tunnel that cannot carry it (2026-10-30)

User report: *"why when using this wireguard, i have plenty of ssl errors"*, then *"THE CA IS TRUSTED
AND ALL WORKING FINE. BUT NOT WITH THIS WIREGUARD, IT CAN DO SOME, BUT MANY ERRORS"*, then the
decisive datum: *"still the same with no proxy"* — i.e. no Burp in the path at all. So the fault was
in the tunnel, and the CA/pinning advice was beside the point.

The profile routes `0.0.0.0/0, ::/0` into the tunnel, and the tunnel is IPv4-only: no IPv6 address, no
IPv6 forwarding, no IPv6 masquerade, zero IPv6 rules. On any dual-stack network (most Wi-Fi, and
cellular) the client tries IPv6 first for nearly every site, and the app reports the result as a TLS or
connection failure.

Measured, in a netns client against a real tunnel:

1. **IPv6 into the tunnel got nothing back** — `ping6` ran the full 3007 ms timeout (a black hole).
2. **The nft reject rule never fired** (counter 0), because an IPv6 packet with no route dies during
   *route lookup*, before any forward-hook rule, and without an IPv6 address on the tunnel the kernel
   cannot even source the ICMPv6 that would say so.
3. After adding the reject in prerouting it *still* fired 0 and still took 3004 ms: WireGuard itself
   was dropping the packet **inside** the tunnel, because the peer's `AllowedIPs = 10.13.37.2/32` did
   not cover the IPv6 source address (cryptokey routing). Three separate layers were swallowing it.

The fix, in three parts — each one necessary, and each proven by the timing test:

* `ula_base()` / `server_ip6()` / `client_ip6()` — a ULA link address on both ends of the tunnel,
  derived from the IPv4 subnet (`10.13.37.0/24` -> `fd13:37::/64`), purely so the kernel can source an
  ICMPv6 answer. It is never used for routing.
* `wgb_guard` — a new `prerouting` chain (priority raw) that rejects IPv6 arriving on the tunnel with
  `icmpv6 type no-route`, i.e. before route lookup, where such a packet would otherwise vanish.
* The peer's AllowedIPs now carry the client ULA (`10.13.37.2/32, fd13:37::2/128`), and `conf_peers`
  takes only the first (IPv4) entry, so inventory, `list` and address allocation are unaffected.

`::/0` deliberately stays in the client profile: dropping it would send the phone's IPv6 to the
internet **around** the interception — a silent bypass of the proxy, which is worse than the errors.

Result: IPv6 into the tunnel now fails in **4 ms instead of 3004 ms**, the guard counter confirms the
packets arrived and were answered, and the client still routes IPv6 into the tunnel so nothing leaks.
The end-to-end suite asserts the timing, the counter, the profile contents and the route, so this
cannot silently regress.

Numbers: **179 unit + 327 netns + 43 tunnel = 549 assertions**, all passing, shellcheck clean.

### Reading the proxy's TLS alerts, and the slowness triage (2026-10-30)

Follow-ups from the same on-site session, both now in the tool's own help instead of my head:

* **A TLS alert in the proxy log comes FROM the client.** The user saw
  `The client failed to negotiate a TLS connection: (certificate_unknown) Received fatal alert:
  certificate_unknown` and read it as the proxy failing. It is the phone refusing Burp's certificate.
  `wgb ca` now decodes the three shapes: `certificate_unknown`/`bad_certificate` = the client refused
  the CA (Android 7+ user-store rule first, then pinning - told apart by whether the phone browser is
  fine and whether the errors cluster on one app's backend hosts); `handshake_failure`/
  `protocol_version` = TLS version or cipher mismatch, not trust; a connection that closes with no
  alert at all = the listener is missing "Support invisible proxying".
* **Slowness ("took too long to respond", timeouts) on the phone.** Three causes with three different
  fixes, so it has to be measured, not guessed: the proxy holding requests (intercept left on), the
  path MTU (large packets dropped - timed with a `ping -M do -s <mtu-40>` sweep over the tunnel), and
  DNS (the ruleset forces port 53 to one resolver; measure `dig +stats` against the alternatives, and
  keep the phone's Private DNS off, since opportunistic DoT is either redirected into the proxy or
  bypasses the port-53 redirect). In this session it was the phone's secure DNS: turning it off fixed
  it, which is why the checklist says so out loud.

Numbers: **181 unit + 327 netns + 43 tunnel = 551 assertions**, all passing, shellcheck clean.

### The default peer is `client`, not `phone` (2026-10-30)

User: *"please don't use "phone" as the client. just used "client" or "client1" for naming. because the
peer is can be used by other device than a phone right?"* Correct - the WireGuard peer is whatever
device imports the profile (phone, tablet, laptop, a second phone), so the demo name was making an
assumption the tool has no business making.

* `--clients 1` now yields **`client`**, `--clients N>1` yields `client1..clientN` (keeping the
  existing rule that the single-client case does not get a number, so every example and the QR path
  stay unchanged in shape).
* `first_client_name()` falls back to `client`, so `wait`'s instruction and the timeout playbook name
  the real peer when one exists.
* Wording that means "the device" changed from phone to client throughout, in the code, README and the
  help. Guidance that is genuinely Android/iOS-specific (Private DNS, the CA store, Always-on VPN) is
  now labelled `Android/iOS client:` instead of `Phone:`, because a laptop client does not need any of it.
* Nothing breaks for an existing setup: peers are read from the server config, so a session already
  holding a peer named `phone` keeps it, keeps working, and is not re-keyed. The rename only decides
  the name of peers created from now on.

Numbers after the rename: **181 unit + 337 netns + 43 tunnel = 561 assertions**, all passing,
shellcheck clean, and no occurrence of "phone" left in the code, the tests or the goldens.

Verifying the rename on this host also exposed a small honesty gap in `--purge`, now fixed: each
session writes its OWN timestamped profile directory, so `down --purge` (which removes this session's
artifacts) can leave an earlier directory on disk - with a client private key in it - and it said
nothing. It now names those directories and says what they hold. Tested with two sessions under one
output base.

### `install.sh`: putting the tool on `PATH` (2026-10-30)

The tool was only ever run as `./wgb` from the checkout. `install.sh` installs it properly:

* **`/usr/local` by default, `/usr/bin` when sudo cannot see `/usr/local/bin`.** This was measured, not
  assumed: this host's sudoers has `secure_path="/usr/sbin:/usr/bin:/sbin:/bin"`, so a `/usr/local/bin`
  install gave `sudo wgb version` -> `command not found` even though the file was there and 0755. Since
  every privileged verb goes through sudo, a bin directory sudo cannot see makes the tool unusable, so
  the installer reads `secure_path` (last definition wins: sudoers, then `sudoers.d` in sorted order),
  and moves to `/usr/bin` when the default is not on it. An explicit `--prefix`/`--bindir` is always
  honoured, with a warning. If sudoers cannot be read it says it could not check rather than guessing.
* **A root-owned copy, never a symlink** (unless `--link`, which warns). wgb runs as root; a symlink
  into a user-writable checkout means any process running as that user - or a `git pull` - decides what
  root executes next. Same rule the tool already enforces on `--config-dir`.
* Replaced atomically (temp file + rename in the target directory, the way wgb writes its own configs),
  so sudo can never execute a half-written script.
* Also installs: bash completion (`share/bash-completion/completions/wgb`), `README.md` and `LICENSE`
  under `share/doc/wgb`. Every path is written to `share/wgb/install-manifest`, which is what
  `--uninstall` reads - so removal is exact and a manifest edited to point outside its prefix deletes
  nothing. `--destdir` stages for packaging; `--dry-run` prints the plan; `--force` is needed to
  overwrite a file at the install path that this installer did not write.
* Refuses to run without root when the target tree is not writable, and asks for `sudo` in the message.

Four defects were found while building and verifying it, three of them in the installer itself:

1. **Usage errors exited 1, not the documented 2.** `usage; die "..."` uses `die` (exit 1). The
   installer's own test caught it; now `usage_die` (exit 2, usage text to stderr) - the same contract
   `wgb` keeps.
2. **`--uninstall` treated every manifest line as a path.** It stripped an optional `path ` prefix and
   processed the rest, so the header and metadata lines (`version`, `source`, `prefix`, `link`) were
   "skipped" with five bogus `outside the recorded prefix` warnings. The prefix guard saved it from
   deleting anything, but the output was a lie. Found on the first real uninstall; now only `path `
   lines are considered.
3. **`--uninstall` could not find a manifest under the prefix the install had actually used.** An
   install that auto-switched to `/usr/bin` records its manifest under `/usr`, and a bare
   `sudo ./install.sh --uninstall` (default prefix `/usr/local`) reported "nothing installed here to
   remove". Fixed with a candidate search - which then had to be **scoped**: the first version let a
   non-root test reach the *real* `/usr` install on this host. The search now runs only as root, or
   inside a `--destdir` staging root; a non-root caller stays in its own prefix. Caught by the test
   suite before it removed anything, and pinned by an assertion that says exactly that.
4. **Sourcing `install.sh` applied its `set -e` to the test harness**, which then exited mid-run when a
   command under test failed - the trap `wgb`'s own header documents for itself. The installer now
   guards strictness with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]`, like wgb.

Tested by `test/install-test.sh`: **95 assertions**, no root, every install goes to a scratch prefix or
a `--destdir` staging root. It covers install/idempotent re-install/`--dry-run` leaves nothing/`--link`
symlinks and warns/`--destdir` staging/`--force`/foreign-file refusal/exact uninstall/a doctored
manifest deleting nothing/a non-root uninstall staying in its prefix/the sudoers parsing (last
definition wins, comments ignored, no partial string matches), and it asserts the completion cannot
drift from `--help` - every `--flag` in the help must be in the completion and vice versa.

CI lints `install.sh`, `completions/wgb.bash` and `test/install-test.sh` and runs the installer test.

Also corrected here: the README status line was stale (it still claimed 103/74/21 assertions), and the
"Phone-side checklist" heading had survived the phone -> client rename.

Numbers now: **181 unit + 95 installer + 337 netns + 43 tunnel = 656 assertions**, all passing,
shellcheck clean.

### Their own `doctor` output reviewed (2026-10-30)

The user ran `wgb` and `wgb doctor` on their machine and pasted both. Checking the output against the
code found nothing wrong in behaviour, and two defects in what it *printed*:

* `--help` still advertised `3 not implemented yet` as an exit code. Nothing emits 3 any more (the
  unit suite asserts no verb is a stub), so the line was a contract the tool no longer keeps. Removed
  from `--help`; the contract section here says what it was.
* The `--endpoint` help line lost one space of column alignment when the client was renamed from
  `phone` (5 characters) to `client` (6). Fixed.

What their output actually says, for the record:

* WAN `eth0`, a private LAN address and a public address behind NAT (**both redacted** - this log ships
  with the repository, and the tool's own output is where real values belong). Because the host does not
  hold the public address, the default endpoint is the LAN address: the client must be on that network,
  or UDP 51820 has to be forwarded. The tool said exactly that.
* `ip_forward is currently 1` with no session up: something else on that host already forwards
  (docker/libvirt/another VPN/manual). Not a problem and not wgb's business - `up` records 1 as the
  prior value and `down` puts 1 back, which is the behaviour the risk register asked for.
* `ufw is installed` -> on `sudo wgb up` the firewall coordination will engage: if ufw owns the
  forwarding policy, `up` adds the route rule, records it, and `down` removes exactly that. That is
  the defect that started this whole thread.
* **`ipv6: this host has a global IPv6 address but the tunnel does not carry IPv6`** -> the WARN
  branch fires on that machine, unlike this host. It is the one real limitation the output exposes:
  IPv6 is rejected inside the tunnel (so apps fall back to IPv4 at once), which keeps interception
  coverage but makes an IPv6-ONLY endpoint unreachable. Carrying IPv6 is feasible on a host that has
  it, and would remove the fallback entirely - offered to the user as the next piece of work, since
  v1 deliberately excluded it (D10).

Numbers: **181 unit + 337 netns + 43 tunnel = 561 assertions**, all passing, shellcheck clean.

### CI went red on the first push: shellcheck version skew (2026-10-30)

The first GitHub Actions run failed on the lint step:

    In wgb line 1108:
      rmdir "$OUT_BASE" 2>/dev/null && log "removed empty $OUT_BASE" || true
                                    ^-- SC2015 (info): Note that A && B || C is not if-then-else.

Two separate problems, and only one of them was the code:

1. **The finding was real** - a style nit, but a real one: `A && B || C` runs C when A succeeds and B
   fails, which is not what the line meant. Rewritten as `if rmdir ...; then log ...; fi`: same
   behaviour, no ambiguity, and no suppression.
2. **The reason a clean local run went red is version skew.** This box has shellcheck 0.11.0; Ubuntu
   24.04 ships 0.9.0, and the two disagree about which checks fire (0.11.0 does not report SC2015 for
   that line, 0.9.0 does). A lint gate that depends on which shellcheck the machine happens to have is
   not a gate.

Fixed structurally: **`test/lint.sh` is now the single lint gate.** It pins `SHELLCHECK_VERSION=0.11.0`,
runs shellcheck over the same file list, parses the zsh completion with `zsh -n`, and warns when the local
version differs from the pin. CI installs exactly the pinned version - read out of that file, so there is
one source of truth - and runs `./test/lint.sh`; README and CONTRIBUTING point at the same script. Verified
by running the gate under both 0.9.0 and 0.11.0: clean on both.

A small trap found while writing it: a comment beginning with the word `shellcheck` is parsed as a
directive (`SC1073: Couldn't parse this shellcheck directive`), so the comment explaining that shellcheck
cannot read zsh had to be reworded.

Numbers: **181 unit + 125 installer + 337 netns + 43 tunnel = 686 assertions**, lint clean on both
shellcheck versions, goldens unchanged.

### "Why this exists" now says what the project is (2026-10-30)

User: *"in 'Why this exists' just tell them that this project is the automatic version of the wg-config,
so that the user don't need to manually setup the wireguard server."* Right - the section was a nine-row
trap table arguing why the tool is careful, which is not what a reader arriving from a link needs first.
It is now one paragraph of lineage: this is the automated version of
[`wg-config`](https://github.com/patarisac/wg-config) (public, so it is linked), which generated the
configs in a browser and left the server setup, the routing/firewall rules and the teardown to the
operator; `wgb` does that work and hands over a client profile.

The trap table is gone from the README, and nothing is lost by that: the failure modes are the body of
`docs/troubleshooting.md`, the flags that address them are in `wgb --help`, and the reasoning is in this
log. README: 191 → 185 lines, 1,781 → 1,646 words.

### The README was 3,000 words; now it is 1,800 (2026-10-30)

User: *"i think the readme.md need to be simplified. what do you think?"* - right, and measurable: 311
lines / 3,017 words is an article. The two biggest sections were also the two that do not belong at the
front door: **Install** (57 lines, mostly justification prose) and **Troubleshooting** (63 lines / 695
words of reference material).

* **README: 311 → 191 lines, 3,017 → 1,781 words.** What it keeps is what a first-time reader needs:
  what it is, the three commands, requirements, why it exists (the trap table, which is the best thing in
  it), install, quick start, the client-side checklist, a symptom → section index, testing, limitations,
  contributing, licence. The `What it guarantees` section is gone: its claims are in the trap table, in
  the quick-start prose, or in PLAN.md, and a README that argues for its own quality twice is a README
  that reads as insecure.
* **`docs/troubleshooting.md` is new** (108 lines) and holds the reference material, reorganised by
  symptom instead of by implementation order: `doctor` first, then "handshake up, nothing loads" (with
  the counters and the other-firewall's `policy drop`), SSL errors with a trusted CA (IPv6, then MTU),
  reading an alert in the proxy log, slowness, `wait` timing out, and a stale profile the app rejects.
  PLAN.md is the log, not documentation - nobody should have to read 1,750 lines of it to fix a timeout.
  `install.sh` installs it alongside README and LICENSE (`share/doc/wgb/troubleshooting.md`).
* Long justifications for `/usr/local` vs `/usr/bin` and for the completion's `fpath` are compressed to
  the decision plus one sentence. The full reasoning is in `install.sh`'s header and in this log, which is
  where a reader who wants it will be.

**And the simplification found a real bug.** Checking that an uninstall leaves nothing behind showed that
after an install that had auto-switched to `/usr`, `--uninstall` removed all six files and then left
**four empty directories** behind - because the manifest-search path updated `MANIFEST`/`LIBDIR` but not
`DOCDIR`/`COMPDIR`/`ZSHDIR`, so the pruning ran against `/usr/local/...` while the files had been under
`/usr/...`. Fixed by deriving all four paths in one place (`set_prefix_paths`), used by the argument
parser, the sudo-reachability switch and the uninstall search. A second, subtler defect came out of the
first fix: `set_prefix_paths` adds the staging root, and the search was handing it a candidate that
already had it - doubly rooted, pruning nothing. Both are now covered by assertions on a staged install
(the directories must be gone, not just the files): **125 installer assertions**.

Numbers: **181 unit + 125 installer + 337 netns + 43 tunnel = 686 assertions**, all passing, shellcheck
clean, goldens unchanged.

### Shell completion: bash had drifted, zsh was missing (2026-10-30)

User: *"for the completions please make sure the bash one is updated, also add zsh completions."* Both
were true complaints, and checking rather than assuming found four things:

1. **The bash completion was missing `--version`.** It was accepted by the parser (`wgb --version`) and
   listed in the help, but not offered by tab completion. The existing drift test compared the
   completion against `wgb --help` - and *still passed*, because the help's own mention of `--version`
   came from the `wgb version | --help` usage line rather than an option line, so the two lists were
   compared on text that had nothing to do with the parser. The drift check now extracts the flags from
   **`parse_args()` itself**, which is the only source of truth, and requires all three lists (parser,
   bash, zsh) to agree exactly.
2. **The bash completion broke under `set -u`.** Typing `wgb <TAB>` with no verb yet left `verb` unset,
   and the completion died with `verb: unbound variable` instead of offering the verbs - for any user
   with `set -u` in their shell. Only calling the function the way bash calls it (set `COMP_WORDS` and
   `COMP_CWORD`, run `_wgb`, read `COMPREPLY`) caught it; the file parsed and shellchecked clean. The
   test suite now does exactly that, with assertions on six real keystrokes.
3. **zsh completion added** (`completions/_wgb`), a `#compdef` file with per-verb `_arguments` specs,
   the same flag sets, and the same value completions (live interfaces for `--iface`/`--wan`, `_directories`
   for `--config-dir`).
4. **Two zsh facts that would have shipped silently broken**, both measured against a real zsh 5.9.2:
   * zsh loads a completion only from a directory on its `fpath`. On Debian
     `/usr/local/share/zsh/site-functions` **is** on the default fpath and
     `/usr/share/zsh/site-functions` is **not** - so an install that auto-switched to `/usr` would put
     a working file where zsh never looks. `install.sh` now checks its choice against zsh's actual
     fpath and prints the one line for `~/.zshrc` when they differ.
   * compinit refuses a completion file that group or others can write: the same file installed 0644
     root:root at `/usr/local/share/zsh/site-functions` registers (`_comps[wgb]=_wgb`) and at 0664 does
     not. The installer installs 0644, and the test asserts the mode.
   * A third, about testing itself: a stale `~/.zcompdump` makes compinit skip rescanning, so a
     completion can look unregistered when it is fine. The zsh checks use a fresh dump (`compinit -C -d
     /dev/null`), the same lesson as `hash -r` for bash.

Numbers: **181 wgb unit + 119 installer + 337 netns + 43 tunnel = 680 assertions**, all passing,
shellcheck clean, goldens unchanged (a completion is not rendered output).

### Disclosure: this project is AI-assisted (2026-10-30)

User: *"i want to add an information / disclaimer that this project is AI-assisted / vibe-coded"*. Added,
then **cut back on the user's feedback that the first version was "exaggerated or too much"** - which it
was: a three-line notice under the README title, a 30-line section with five bullets, a paragraph in
CONTRIBUTING.md, a section in SECURITY.md, and three lines in each script header is a manifesto, not a
disclaimer.

What ships now:

* **README** - one italic line after the status paragraph: *"AI-assisted: a coding agent wrote most of
  this, directed and verified by a human - there has been no line-by-line human review, so read it before
  you run it as root."* It states the fact and the one consequence a reader has to act on (a root-running
  tool nobody reviewed line by line), and stops.
* **`wgb` and `install.sh` headers** - one line each: `# AI-assisted: a coding agent wrote most of this
  (see README.md).` Someone who copies the script alone still gets the fact.

Removed: the README section, the CONTRIBUTING paragraph, the SECURITY section. The removed material is
already in this log (the split of work, what the tests cover, what only live runs could have found), and
PLAN.md is public - so nothing is hidden by trimming the README, the claims just are not restated five
times. The agent is not named, and the word "vibe-coded" is not used: its usual reading is *unverified*,
which is not what 656 assertions and a documented list of gaps are.

### What is still NOT verified

Stated plainly so no future session mistakes these for tested behaviour:

1. **A physical phone.** QR import through the WireGuard app, Private DNS, Always-on VPN, the CA
   install and the Android 7+ user-store limitation are all phone-side and unexercised. The
   namespaces prove the data path, not the device.
2. **TLS interception by the proxy itself.** The end-to-end test carries cleartext HTTP. The
   tool's own claim — traffic leaving the client lands on the proxy port — is proven; "Burp then
   intercepts TLS using the phone's CA" is not, and cannot be from here.
3. **CLOSED — a real `sudo` invocation on the host (2026-10-24).** Run, verified and torn down;
   the record is in the section above. `/etc/wireguard`, `/run/wgb`, `out/` and a real
   `SUDO_USER` are all now exercised for real.
4. **CLOSED — the ufw interaction against a live ufw (2026-10-29).** Installed, exercised (add,
   repeat, teardown, doctor) and purged; see the live-ufw section above. Every ufw claim is now
   verified against ufw's own binary, not only its source and a stand-in.
5. **Concurrency and duration.** Two simultaneous sessions on different interfaces (the code warns
   and picks the newest), and anything that only appears over hours (rekeys, keepalive). The unclean
   kill mid-bring-up case is now tested.
6. **Coordination with another firewall manager — ufw done, the rest still advisory.** Since
   2026-10-29 `up` applies the ufw route rule itself and `down` reverts exactly that, verified against
   a live ufw. For firewalld and hand-rolled iptables chains the tool still only names the owner and
   the command that product documents, and that path has no test against a real firewalld.
   `--purge` against the real `/etc/wireguard` is tested, including removal of the backups it created.
