# Contributing

See the [README](README.md) for setup and [SECURITY.md](SECURITY.md) for private vulnerability reports.

## Before you open a PR

```bash
./test/run-tests.sh                  # unit + render layer, no root
./test/install-test.sh               # install/uninstall in a scratch prefix, no root
sudo ./test/integration-netns.sh     # real up/down cycles in a throwaway namespace
sudo ./test/integration-tunnel.sh    # a real WireGuard client's traffic reaching the proxy port
./test/lint.sh                       # local ShellCheck + zsh syntax check
```

`test/lint.sh` reports when the installed ShellCheck differs from the project's expected version.

[GitHub Actions](.github/workflows/ci.yml) runs the macOS PF syntax, WireGuard lifecycle, and live
delivery checks. The live job sends plain HTTP from an independent WireGuard peer through a
disposable PF anchor to a test listener and checks cleanup. It does not run Burp or test HTTPS.

Run the Linux checks above locally. The namespace and tunnel suites can skip with exit 0 if root,
namespace tooling, or WireGuard kernel support is unavailable. In a PR that changes the network
apply path or firewall rules, report which tests ran and which skipped.

`WGB_TEST_DEBUG=1` makes a failing assertion dump the captured output it was checking.

## House rules

These are not style preferences; each one exists because breaking it caused a bug that shipped.

* **Two layers, hard boundary.** `render_*` functions emit text and touch nothing; `apply_*` functions
  write files and exec things. Anything generated must be testable without root, a tunnel or a network.
* **Validate generated config with the real consumer.** Use `nft -c -f` on Linux or the native PF
  no-load syntax check on macOS. `wg-quick strip` checks config processing; a live peer test checks
  that WireGuard actually accepts and uses the profile.
* **Golden fixtures are a regression signal, not a build artifact.** Regenerating them to silence a red
  test throws away the only warning that the generated output changed. Regenerate with
  `./test/update-golden.sh` only when the change to the output is intended, and read the diff.
* **A repeat run never destroys state**, and teardown restores the PRIOR value of anything the tool
  flips - never a hardcoded default.
* **Every path overridable by env** (`WGB_STATE_DIR`, `WGB_ETC_DIR`, `WGB_OUT_BASE`, `WGB_INDEX_DIR`),
  so tests never touch the real machine.
* **Source-guard anything a test sources**: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then set -euo
  pipefail; fi`. Sourcing must not mutate the caller's shell options.
* **Exit codes are a contract**: `0` ok, `1` runtime failure, `2` usage error. A bad invocation exits 2.
* **Say what is true.** If output claims a guarantee, there is a test that proves it. Stale claims are
  bugs - fix the code and the claim together.

## Scope

The tool is deliberately narrow: bring up a tunnel on the machine you are sitting at, drive the
client's traffic through a local interception proxy, tear everything down again. Remote/VPS
provisioning, an obfuscated transport for filtered UDP, and IPv6 carriage inside the tunnel are known,
documented gaps rather than oversights - `PLAN.md` records why each is out of v1, and that reasoning is
worth reading before proposing one of them.

`PLAN.md` is the working design log, kept in the open on purpose. It is a log, not documentation:
expect it to argue with itself in places, because that is what the decisions looked like at the time.

## License

MIT. By contributing you agree your work is licensed the same way.
