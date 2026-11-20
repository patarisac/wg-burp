# Security policy

## Reporting

Please report a vulnerability **privately**, through GitHub's
[security advisories](https://github.com/patarisac/wg-burp/security/advisories/new) for this repository
(or email the maintainer if you have their address). Do not report vulnerabilities in a public issue.

Please include `wgb version`, the commit if known, the host OS and version, and the command or steps
that demonstrate the issue. On Linux, include the distribution and kernel version; on macOS, include
the macOS version and architecture. Describe what you expected and what happened. Redact private
keys, client profiles, PF enable tokens, and engagement data from logs and attachments.

## What is in scope

`wgb` runs as root and writes firewall rules, a WireGuard config and client private keys. Things worth
reporting:

* **Command or config injection** through any flag, interface name, endpoint, client name, subnet or
  DNS value that reaches a shell, a generated nftables or PF ruleset, or a generated client profile.
* **A way to make the tool write, chmod or chown something as root that an unprivileged user
  controls** — for example a config directory the tool would accept when it should refuse, or a
  recorded path it would delete or overwrite without checking.
* **Unintended disclosure of key material**: insecure file permissions, keys in logs or journals,
  or current-session keys left behind where `down --purge` says they were removed. Intentional
  profile output from `--print-config` and `qr` contains key material by design.
* **Privilege escalation through the installer**: `install.sh` installing a file that is writable by
  someone other than root, or an `--uninstall` that removes something outside what a previous install
  recorded.
* **A teardown that leaves the machine in a state the operator did not expect**: rules, routes,
  forwarding settings, a leaked PF enable reference, or changes to unrelated firewall rules.

## What is not in scope

* Vulnerabilities in WireGuard, `nftables`, macOS PF, Burp Suite, the client device or the client app. Report
  those upstream.
* The interception itself. This tool routes a device's traffic to a proxy on purpose; a client that
  trusts the proxy CA is the intended configuration, and certificate pinning in an app is not a
  vulnerability in this tool.
* Anything requiring an already-root attacker on the machine, or physical access.
* A version of the tool that has been locally modified.

## Supported versions

The latest release and `main`. This is a small tool maintained in spare time — there is no back-port
policy, and fixes land on `main`.
