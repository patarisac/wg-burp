#!/usr/bin/env bash
#
# Test suite for wgb. Dependency-free: no bats, no root, no network, no tunnel.
#
#   ./test/run-tests.sh
#
# Render-layer tests compare generated config text against the fixtures in test/golden/.
# If generated output changes on purpose, regenerate the fixtures with
#   ./test/update-golden.sh
# and read the diff before committing: the fixture exists so the change had to be
# deliberate. Regenerating to make a red test green defeats the suite.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
WGB="$ROOT/wgb"
GOLDEN="$ROOT/test/golden"

# Source the script as a library. Its source-guard keeps our shell options untouched.
# shellcheck source=../wgb
source "$WGB"
# shellcheck source=lib.sh
source "$ROOT/test/lib.sh"

# Counters, ok/ko and the assert_* helpers live in test/lib.sh and are shared with the
# integration test.
SCRATCH="$(mktemp -d)"
# The profile index is persistent state in /var/lib/wgb by default. Point it (and the sourced
# functions' own copy of it) at the scratch tree so a suite run is hermetic and cannot see profiles
# from earlier runs. INDEX_DIR is assigned after `source wgb`, which is what makes this win.
INDEX_DIR="$SCRATCH/index"
export WGB_INDEX_DIR="$INDEX_DIR"
trap 'rm -rf "$SCRATCH"' EXIT

# assert_golden <name> <fixture> <render function> [args...]
assert_golden() {
  local name="$1" fixture="$2" fn="$3" out diffout
  shift 3
  out="$("$fn" "$@")"
  if diff -u "$fixture" <(printf '%s\n' "$out") >/dev/null 2>&1; then
    ok "$name"
  else
    diffout="$(diff -u "$fixture" <(printf '%s\n' "$out") | head -40)"
    ko "$name" "$diffout"
  fi
}

exists() { [[ -e "$1" ]] && printf 'yes' || printf 'no'; }

# ---------------------------------------------------------------------------
group 'render layer: golden fixtures'
setup_render_env
assert_golden 'server config matches golden fixture' "$GOLDEN/server.conf" render_server_conf
assert_golden 'client config matches golden fixture' "$GOLDEN/client.conf" \
  render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY"
assert_golden 'nftables ruleset matches golden fixture' "$GOLDEN/rules.nft" render_nft

# ---------------------------------------------------------------------------
group 'macOS pilot: PF rule rendering (not a native parser test)'
setup_render_env
PF_OUT="$(render_pf utun42)"
assert_contains 'PF NAT is restricted to the WireGuard subnet and WAN' "$PF_OUT" \
  'nat on wlan0 inet from 10.13.37.0/24 to any -> (wlan0)'
assert_contains 'PF redirects TCP arriving on the live tunnel interface' "$PF_OUT" \
  'rdr on utun42 inet proto tcp from 10.13.37.0/24 to any -> 10.13.37.1 port 8083'
assert_contains 'PF rejects IPv6 only on the tunnel interface' "$PF_OUT" \
  'block return-icmp6 in quick on utun42 inet6 all'
assert_eq 'PF applies DNS translation before catch-all TCP redirection' 'yes' "$(
  awk '/^rdr .*port 53/ { dns=NR } /^rdr .*port 8083$/ { proxy=NR } END { if (dns && dns < proxy) print "yes" }' <<<"$PF_OUT"
)"
assert_contains 'PF blocks QUIC on the tunnel interface' "$PF_OUT" \
  'block drop in quick on utun42 inet proto udp from 10.13.37.0/24 to any port 443'
assert_not_contains 'PF no-proxy mode has no Burp redirect' "$(PROXY_MODE=0 render_pf utun42)" 'port 8083'
assert_not_contains 'PF allow-quic has no QUIC block' "$(BLOCK_QUIC=0 render_pf utun42)" 'port 443'
assert_contains 'PF preserves TCP DNS for a resolver on the tunnel host' \
  "$(DNS=10.13.37.1 render_pf utun42)" 'no rdr on utun42 inet proto tcp from 10.13.37.0/24 to 10.13.37.1 port 53'
maybe_run render_pf wgm0
assert_eq 'PF requires a real utun name rather than the logical config name' '1' "$RC"
maybe_run render_pf utun42 $'en0\npass all'
assert_eq 'PF rejects a malformed uplink before rendering' '1' "$RC"
assert_eq 'PF rejects a nonnumeric proxy port before rendering' '1' "$(BURP_PORT=invalid render_pf utun42; printf '%s' "$?")"
assert_eq 'a dedicated PF hook is accepted' '0' "$(
  pf_has_hook rdr-anchor <<< 'rdr-anchor "wgb/*" all'; printf '%s' "$?"
)"
assert_eq 'the Apple hook does not count as a production hook' '1' "$(
  pf_has_hook rdr-anchor <<< 'rdr-anchor "com.apple/*" all'; printf '%s' "$?"
)"
assert_eq 'a restricted hook does not count as the required unconditional hook' '1' "$(
  pf_has_hook rdr-anchor <<< 'rdr-anchor "wgb/*" on en0 all'; printf '%s' "$?"
)"
assert_eq 'a native PF parse failure never enables PF or loads rules' $'parse\n1' "$(
  live_wg_iface() { printf 'utun42\n'; }
  pf_file() { printf '%s/rejected.pf' "$SCRATCH"; }
  pf_ref_file() { printf '%s/unexpected-reference' "$SCRATCH"; }
  pf() { if [[ "$1" == -n ]]; then printf 'parse\n'; return 1; fi; printf 'unexpected PF %s\n' "$*"; }
  pf_start
  printf '%s\n' "$?"
  [[ ! -e "$(pf_ref_file)" ]] || printf 'unexpected journal\n'
)"
assert_eq 'PF cleanup flushes only the session child and releases its recorded token' \
  $'-a wgb/wgm0 -F rules\n-a wgb/wgm0 -F nat\n-X 18446744073709551615' "$(
  pf_file() { printf '%s/cleanup-rules' "$SCRATCH"; }
  pf_ref_file() { printf '%s/cleanup-reference' "$SCRATCH"; }
  printf 'rule\n' >"$(pf_file)"
  printf 'pf enabled\nToken : 18446744073709551615\n' >"$(pf_ref_file)"
  pf_child_empty() { return 0; }
  pf() { printf '%s\n' "$*"; }
  pf_stop
  [[ ! -e "$(pf_file)" && ! -e "$(pf_ref_file)" ]] || printf 'unexpected journal\n'
)"
assert_eq 'PF retains the reference journal if token release fails' '1 retained' "$(
  pf_ref_file() { printf '%s/retained-reference' "$SCRATCH"; }
  printf 'Token : 42\n' >"$(pf_ref_file)"
  pf() { return 1; }
  pf_stop
  printf '%s ' "$?"
  [[ ! -e "$(pf_ref_file)" ]] || printf retained
)"

# ---------------------------------------------------------------------------
group 'platform preparation: safe WireGuard resync'
assert_eq 'a failed strip never reaches wg' '1' "$(
  log() { :; }
  live_wg_iface() { printf 'utun42\n'; }
  wg-quick() { return 1; }
  wg() { printf 'unexpected wg invocation'; }
  link_up wgm0 2>/dev/null
  printf '%s' "$?"
)"
assert_eq 'sync uses the live interface and the stripped config' 'syncconf utun42 /dev/stdin: [Interface]' "$(
  log() { :; }
  live_wg_iface() { printf 'utun42\n'; }
  wg-quick() { printf '[Interface]\n'; }
  wg() { local line; read -r line; printf '%s: %s' "$*" "$line"; }
  link_up wgm0 2>/dev/null
)"

group 'platform preparation: directory permissions'
assert_eq 'macOS chooses a boot-scoped state path outside the group-writable runtime tree' \
  '/private/var/db/wgb/state-01234567-89AB-CDEF-0123-456789ABCDEF' "$(
  darwin_boot_id() { printf '01234567-89AB-CDEF-0123-456789ABCDEF\n'; }
  darwin_default_state_dir
)"
assert_eq 'macOS refuses an unsafe boot ID instead of selecting a state path' '1' "$(
  darwin_boot_id() { printf '../unsafe\n'; }
  darwin_default_state_dir
  printf '%s' "$?"
)"
mkdir -p "$SCRATCH/group-writable/child"
chmod 0775 "$SCRATCH/group-writable"
chmod 0700 "$SCRATCH/group-writable/child"
assert_contains 'the path guard reports a group-writable ancestor without accepting it' \
  "$(stat() {
    if [[ "$1 $2" == '-f %u' ]]; then printf '0\n'; else command stat "$@"; fi
  }; trusted_root_path "$SCRATCH/group-writable/child/state" 2>&1; printf 'rc=%s' "$?")" \
  "$SCRATCH/group-writable (uid 0, mode 775)"$'\nrc=1'
mkdir "$SCRATCH/config-mode"
chmod 0700 "$SCRATCH/config-mode"
assert_eq 'reads the mode of an existing directory' '700' "$(file_mode "$SCRATCH/config-mode")"
assert_eq 'accepts BSD stat output when GNU stat is unavailable' '770' "$(
  stat() {
    [[ "$*" == "-f %Lp $SCRATCH/config-mode" ]] || return 1
    printf '770\n'
  }
  file_mode "$SCRATCH/config-mode"
)"
assert_eq 'fails closed if directory permissions cannot be inspected' '1' "$(
  # shellcheck disable=SC2329 # Called by file_mode inside assert_conf_dir_safe.
  stat() { return 1; }
  (WG_ETC_DIR="$SCRATCH/config-mode" assert_conf_dir_safe) >/dev/null 2>&1
  printf '%s' "$?"
)"

# ---------------------------------------------------------------------------
group 'structural guarantees'
setup_render_env
SERVER_OUT="$(render_server_conf)"
CLIENT_OUT="$(render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY")"
RULES_OUT="$(render_nft)"

assert_not_contains 'server config emits no PostUp (rules are owned by the tool)' \
  "$SERVER_OUT" 'PostUp'
assert_not_contains 'server config emits no PostDown' "$SERVER_OUT" 'PostDown'
assert_eq 'ruleset owns exactly one table' '1' \
  "$(printf '%s\n' "$RULES_OUT" | grep -c '^table inet wgb {')"

dns_line="$(printf '%s\n' "$RULES_OUT" | grep -n 'dport 53' | head -1 | cut -d: -f1)"
redir_line="$(printf '%s\n' "$RULES_OUT" | grep -n 'redirect to :8083' | head -1 | cut -d: -f1)"
if [[ -n "$dns_line" && -n "$redir_line" ]] && ((dns_line < redir_line)); then
  ok 'port-53 DNAT precedes the catch-all TCP redirect'
else
  ko 'port-53 DNAT precedes the catch-all TCP redirect' "dns line=$dns_line redirect line=$redir_line"
fi

assert_contains 'client routes IPv6 into the tunnel (no carrier leak)' "$CLIENT_OUT" \
  'AllowedIPs = 0.0.0.0/0, ::/0'
assert_contains 'client keeps the cellular-safe MTU' "$CLIENT_OUT" 'MTU = 1380'
assert_contains 'client keeps a keepalive so cellular NAT holds' "$CLIENT_OUT" 'PersistentKeepalive = 25'
assert_contains 'QUIC is dropped from the forward path by default' "$RULES_OUT" \
  'iifname "wgm0" udp dport 443 counter drop'
assert_contains 'tunnel subnet is masqueraded out the WAN interface' "$RULES_OUT" \
  'oifname "wlan0" counter masquerade'
# Regression guards for two nft syntax errors that only nft itself can catch. The
# integration test validates the ruleset with `nft -c`; these keep the mistake from
# being reintroduced in the text at all.
assert_contains 'the TCP redirect is expressed as meta l4proto tcp' "$RULES_OUT" \
  'meta l4proto tcp counter redirect to :8083'
assert_not_contains 'no rule uses a bare tcp redirect (which does not parse)' \
  "$RULES_OUT" '/24 tcp redirect'
assert_not_contains 'no chain is named with the reserved word fwd' "$RULES_OUT" 'chain fwd {'

# ---------------------------------------------------------------------------
group 'client profile content (unit)'
# A profile whose [Peer] has an empty PublicKey or Endpoint passes `wg-quick strip` (it validates no
# content) but is rejected by every client app with "syntax error in Peer". This is the check that
# runs before the file is written.
setup_render_env
assert_eq 'a properly rendered profile has no defect' '' \
  "$(client_profile_defect "$(render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY")")"
# shellcheck disable=SC2034  # read by render_client_conf
SERVER_PUBKEY=""
assert_contains 'an empty server key is a defect' \
  "$(client_profile_defect "$(render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY")")" \
  'the [Peer] PublicKey'
setup_render_env
# shellcheck disable=SC2034  # read by render_client_conf
ENDPOINT=""
assert_contains 'a missing endpoint is a defect' \
  "$(client_profile_defect "$(render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY")")" \
  'the Endpoint'
setup_render_env
# shellcheck disable=SC2034  # read by render_client_conf
ENDPOINT="vpn.example.com"
assert_eq 'a hostname endpoint with a port is not a defect' '' \
  "$(client_profile_defect "$(render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY")")"

# ---------------------------------------------------------------------------
group 'rule conditionals'
# SC2034: toggling these globals IS the test - render_nft (sourced from ../wgb) reads them.
# shellcheck disable=SC2034
setup_render_env
PROXY_MODE=0
assert_not_contains 'PROXY_MODE=0 removes the TCP redirect' "$(render_nft)" 'redirect to :'
setup_render_env
BLOCK_QUIC=0
# Without the counter keyword, so it fails if the rule is present in any form.
assert_not_contains 'BLOCK_QUIC=0 removes the UDP 443 drop' "$(render_nft)" 'udp dport 443'
setup_render_env
DNS="$(server_ip)"
assert_not_contains 'DNS pointing at the server removes the self-referential DNAT' \
  "$(render_nft)" 'dnat to'

# ---------------------------------------------------------------------------
group 'address allocation'
setup_render_env
assert_eq 'first client gets .2' '10.13.37.2' "$(alloc_next_ip)"
assert_eq 'allocator skips live peers' '10.13.37.4' "$(alloc_next_ip 10.13.37.2 10.13.37.3)"
assert_eq 'allocator fills gaps instead of counting up' '10.13.37.2' "$(alloc_next_ip 10.13.37.3)"
assert_eq 'allocator ignores empty entries' '10.13.37.2' "$(alloc_next_ip '' '')"
if (alloc_next_ip 10.13.37.{2..254}) >/dev/null 2>&1; then
  ko 'allocator reports exhaustion' 'expected a non-zero status when the subnet is full'
else
  ok 'allocator reports exhaustion'
fi

# ---------------------------------------------------------------------------
group 'endpoint reachability (unit)'
# "Does this host hold the address I am advertising?" decides whether a client can reach the
# endpoint at all: an address the host does not hold lives at whatever NATs for it.
if endpoint_behind_nat 127.0.0.1; then
  ko 'an address this host holds is not reported as behind NAT' '127.0.0.1 was claimed as remote'
else
  ok 'an address this host holds is not reported as behind NAT'
fi
if endpoint_behind_nat 198.51.100.7; then
  ok 'an address this host does not hold is reported as behind NAT'
else
  ko 'an address this host does not hold is reported as behind NAT' 'no claim was made'
fi
if endpoint_behind_nat example.com; then
  ko 'a hostname is never claimed to be behind NAT' 'a hostname cannot be judged this way'
else
  ok 'a hostname is never claimed to be behind NAT'
fi
SRC="$(route_src_ipv4 || true)"
if [[ -z "$SRC" ]] || is_ipv4 "$SRC"; then
  ok 'the default-route source is either empty or a valid address'
else
  ko 'the default-route source is either empty or a valid address' "got: $SRC"
fi
assert_contains 'the port-forward target hint is never empty' "$(nat_target_hint)" \
  "$([[ -n "$SRC" ]] && printf '%s' "$SRC" || printf 'LAN address')"

# ---------------------------------------------------------------------------
group 'endpoint policy (unit)'
# Deterministic: both lookups are stubbed inside subshells, so the real functions stay in place for
# the CLI tests below. Format: endpoint|is_local|public_candidate
ep_case() { # <public> <route-src> <first-local>
  # Names must not collide with the locals inside choose_default_endpoint: bash scoping is dynamic,
  # so a stub referencing "$pub" would read the callee's own (unset) local instead.
  local EP_PUB="$1" EP_SRC="$2" EP_FIRST="$3"
  (
    detect_public_ip() { printf '%s' "$EP_PUB"; }
    route_src_ipv4() { printf '%s' "$EP_SRC"; }
    local_ipv4() { printf '%s' "$EP_FIRST"; }
    ENDPOINT=""
    ENDPOINT_IS_LOCAL=0
    PUBLIC_CANDIDATE=""
    if choose_default_endpoint; then
      printf '%s|%s|%s' "$ENDPOINT" "$ENDPOINT_IS_LOCAL" "$PUBLIC_CANDIDATE"
    else
      printf 'none'
    fi
  )
}
# The host does not hold the public address, so it must not be advertised: the main local address is
# the one a device on this network can reach, and the public one is kept to be shown as the
# alternative.
assert_eq 'a host behind NAT defaults to its main local address' '10.99.0.5|1|198.51.100.7' \
  "$(ep_case 198.51.100.7 10.99.0.5 10.99.0.9)"
# The host DOES hold the public address: then it is the best answer, cellular included.
assert_eq 'a host that holds the public address uses it' '127.0.0.1|0|' \
  "$(ep_case 127.0.0.1 10.99.0.5 10.99.0.9)"
# No default route: fall back to the first global address.
assert_eq 'without a default route it uses the first local address' '10.99.0.9|1|198.51.100.7' \
  "$(ep_case 198.51.100.7 '' 10.99.0.9)"
# The default route through the tunnel would offer the tunnel's own address as the way in.
assert_eq 'the tunnel address is never advertised as the endpoint' '10.99.0.9|1|198.51.100.7' \
  "$(ep_case 198.51.100.7 10.13.37.5 10.99.0.9)"
assert_eq 'nothing to advertise is reported, not invented' 'none' "$(ep_case '' '' '')"
# An explicit --endpoint always wins, whatever the policy would have chosen.
assert_eq 'an explicit endpoint is never overridden' '203.0.113.9' \
  "$( (ENDPOINT=203.0.113.9; resolve_endpoint; printf '%s' "$ENDPOINT") )"
if (
  detect_public_ip() { :; }
  route_src_ipv4() { :; }
  local_ipv4() { :; }
  ENDPOINT=""
  resolve_endpoint
) >/dev/null 2>&1; then
  ko 'up refuses when no endpoint can be determined' 'expected a non-zero status'
else
  ok 'up refuses when no endpoint can be determined'
fi

# ---------------------------------------------------------------------------
group 'cli: dry run and preflight (no root)'
STATE_BEFORE="$(exists "$STATE_DIR")"
maybe_run "$WGB" up --dry-run --endpoint 192.0.2.10 --wan wlan0
assert_eq 'dry run exits 0' '0' "$RC"
assert_contains 'dry run prints a plan' "$OUT" 'dry run, nothing will be changed'
assert_contains 'dry run explains the intercept path' "$OUT" 'COMMANDS THAT WOULD RUN'
assert_contains 'dry run warns about the proxy bind address' "$OUT" 'never 127.0.0.1'
assert_contains 'dry run warns about Android Private DNS' "$OUT" 'Private DNS to Off'
assert_contains 'dry run warns about the CA store' "$OUT" 'user-store CAs are ignored'
assert_contains 'dry run states the MTU' "$OUT" 'MTU 1380'
assert_contains 'dry run names the endpoint' "$OUT" '192.0.2.10'
assert_eq 'dry run changes no state' "$STATE_BEFORE" "$(exists "$STATE_DIR")"

# An auto-detected endpoint on a NATed machine belongs to the NAT, not to this host. The plan is
# the artifact the operator reads before touching anything, so it has to say so.
maybe_run "$WGB" up --dry-run --endpoint 198.51.100.7 --wan wlan0
assert_eq 'dry run with a remote endpoint exits 0' '0' "$RC"
assert_contains 'dry run flags an endpoint this host does not hold' "$OUT" \
  'not an address this host holds'
assert_contains 'and names the address a forward would target' "$OUT" 'forwarded to'
maybe_run "$WGB" up --dry-run --endpoint example.com --wan wlan0
assert_eq 'a hostname endpoint still plans cleanly' '0' "$RC"
assert_not_contains 'a hostname endpoint is never claimed to be behind NAT' "$OUT" \
  'not an address this host holds'

maybe_run "$WGB" up --print-config --endpoint 192.0.2.10 --wan wlan0
assert_eq 'print-config exits 0' '0' "$RC"
assert_contains 'print-config prints the server block' "$OUT" 'ListenPort = 51820'
assert_contains 'print-config prints a client block' "$OUT" 'Endpoint = 192.0.2.10:51820'
assert_not_contains 'print-config prints no plan chatter' "$OUT" 'COMMANDS THAT WOULD RUN'

maybe_run "$WGB" up --print-rules --endpoint 192.0.2.10 --wan wlan0
assert_eq 'print-rules exits 0' '0' "$RC"
assert_contains 'print-rules prints the owned table' "$OUT" 'table inet wgb {'
assert_contains 'print-rules prints the interception rules' "$OUT" 'redirect to :8083'

maybe_run "$WGB" doctor --endpoint 192.0.2.10 --wan wlan0
if [[ "$RC" == 0 || "$RC" == 1 ]]; then
  ok 'doctor exits 0 or 1'
else
  ko 'doctor exits 0 or 1' "got $RC"
fi
assert_contains 'doctor reports capabilities' "$OUT" 'CAPABILITIES'
assert_contains 'doctor checks the proxy bind' "$OUT" 'LISTENERS'
assert_contains 'doctor states the UDP transport caveat' "$OUT" 'filtered UDP'
assert_contains 'doctor has a coexisting-firewall section' "$OUT" 'COEXISTING FIREWALLS'
assert_contains 'doctor says the forward-chain cross-check needs root' "$OUT" 'needs root'
maybe_run "$WGB" doctor --endpoint 198.51.100.7 --wan wlan0
assert_contains 'doctor explains an endpoint that lives at a NAT' "$OUT" 'behind NAT'
assert_contains 'doctor names the address a forward would have to target' "$OUT" "$(nat_target_hint)"

# ---------------------------------------------------------------------------
group 'cli: argument validation'
maybe_run "$WGB" up --dry-run --mtu 9999 --endpoint 192.0.2.10 --wan wlan0
assert_eq 'bad MTU is a usage error' '2' "$RC"
maybe_run "$WGB" up --dry-run --subnet 10.0.0.0/16 --endpoint 192.0.2.10 --wan wlan0
assert_eq 'non-/24 subnet is a usage error' '2' "$RC"
maybe_run "$WGB" up --dry-run --dns not-an-ip --endpoint 192.0.2.10 --wan wlan0
assert_eq 'non-IP DNS is a usage error' '2' "$RC"
maybe_run "$WGB" up --clients 0 --dry-run --endpoint 192.0.2.10 --wan wlan0
assert_eq 'zero clients is a usage error' '2' "$RC"
maybe_run "$WGB" --bogus-flag
assert_eq 'unknown option is a usage error' '2' "$RC"
maybe_run "$WGB" nonsense
assert_eq 'unknown command is a usage error' '2' "$RC"
maybe_run "$WGB" up --dns
assert_eq 'an option missing its value is a usage error' '2' "$RC"
maybe_run "$WGB" up --dry-run --config-dir relative/conf --endpoint 192.0.2.10 --wan wlan0
assert_eq 'a relative config directory is a usage error' '2' "$RC"
assert_contains 'the refusal explains why' "$OUT" 'absolute path'
maybe_run "$WGB" up --dry-run --config-dir /var/tmp/wgb-conf --endpoint 192.0.2.10 --wan wlan0
assert_eq 'an absolute config directory is accepted' '0' "$RC"
assert_contains 'the plan names the config directory' "$OUT" '/var/tmp/wgb-conf/wgm0.conf'

# Anything interpolated into the ruleset or into a profile is validated before it gets there:
# --wan goes into nft syntax, --endpoint into the profile the client imports.
maybe_run "$WGB" up --dry-run --wan 'eth0" ; flush ruleset; #' --endpoint 192.0.2.10
assert_eq 'an interface name carrying nft syntax is a usage error' '2' "$RC"
assert_contains 'the refusal names the offending flag' "$OUT" 'invalid --wan'
maybe_run "$WGB" up --dry-run --wan wlan0 --endpoint "$(printf '192.0.2.10\nPersistentKeepalive = 0')"
assert_eq 'an endpoint containing a newline is a usage error' '2' "$RC"
assert_contains 'the refusal says what an endpoint may be' "$OUT" 'IPv4 address or a hostname'
maybe_run "$WGB" up --dry-run --wan wlan0 --endpoint example.com
assert_eq 'a hostname endpoint is accepted' '0' "$RC"
maybe_run "$WGB" up --dry-run --wan wlan0 --endpoint 10.0.0.0/24
assert_eq 'a CIDR as an endpoint is a usage error' '2' "$RC"
# Leading zeros are rejected rather than guessed at: resolv.conf, nft and the wg tools all treat
# them differently, and bash would read "08" as a broken octal.
maybe_run "$WGB" up --dry-run --dns 08.8.8.8 --endpoint 192.0.2.10 --wan wlan0
assert_eq 'a leading-zero octet is a usage error' '2' "$RC"
assert_eq 'and it produces no bash arithmetic error' '0' \
  "$(printf '%s' "$OUT" | grep -c 'value too great for base' || true)"

# ---------------------------------------------------------------------------
group 'cli: privileged paths refuse without root'
if [[ "$(id -u)" == 0 ]]; then
  printf '  skip (running as root: the refusal path cannot be exercised)\n'
else
  maybe_run "$WGB" up --endpoint 192.0.2.10 --wan wlan0
  assert_eq 'up without root refuses' '1' "$RC"
  assert_contains 'the refusal names the fix' "$OUT" 'sudo'
  maybe_run "$WGB" down
  assert_eq 'down without root refuses' '1' "$RC"
  assert_eq 'the refusal is not a usage error' '1' "$RC"
fi

# ---------------------------------------------------------------------------
group 'cli: status is read-only and root-tolerant'
maybe_run "$WGB" status
assert_eq 'status exits 0' '0' "$RC"
assert_contains 'status reports the interface section' "$OUT" 'INTERFACE '
assert_contains 'status reports the rules section' "$OUT" 'RULES (table inet wgb)'
assert_contains 'status reports forwarding state' "$OUT" 'net.ipv4.ip_forward'

# ---------------------------------------------------------------------------
group 'session state round trip (unit)'
setup_render_env
# shellcheck disable=SC2034  # read by render_state_file
OUTDIR="$SCRATCH/out/20260101T000000Z"
# shellcheck disable=SC2034  # read by render_state_file
PRIOR_IP_FORWARD="0"
# shellcheck disable=SC2034  # read by render_state_file
BACKUPS=("/etc/wireguard/wgm0.conf.bak-20260101T000000Z")
STATE_FIXTURE="$SCRATCH/state.env"
render_state_file >"$STATE_FIXTURE"
assert_eq 'state records the interface' 'wgm0' "$(state_get IFACE "$STATE_FIXTURE")"
assert_eq 'state records the WAN interface' 'wlan0' "$(state_get WAN_IFACE "$STATE_FIXTURE")"
assert_eq 'state records the prior ip_forward value' '0' "$(state_get PRIOR_IP_FORWARD "$STATE_FIXTURE")"
assert_eq 'state records the output directory' "$OUTDIR" "$(state_get OUTDIR "$STATE_FIXTURE")"
assert_eq 'state records the config directory' "$WG_ETC_DIR" "$(state_get CONF_DIR "$STATE_FIXTURE")"
assert_eq 'state records the output base' "$OUT_BASE" "$(state_get OUT_BASE "$STATE_FIXTURE")"
assert_eq 'state records the backups this session made' "${BACKUPS[0]}" \
  "$(state_get BACKUPS "$STATE_FIXTURE")"
assert_eq 'state records the resolver' '1.1.1.1' "$(state_get DNS "$STATE_FIXTURE")"
assert_eq 'state records the proxy mode' '1' "$(state_get PROXY_MODE "$STATE_FIXTURE")"
if (state_get NO_SUCH_KEY "$STATE_FIXTURE") >/dev/null 2>&1; then
  ko 'a missing state key fails cleanly' 'expected non-zero status'
else
  ok 'a missing state key fails cleanly'
fi

# A state file is data, never code: teardown runs as root and must not execute it.
EVIL_STATE="$SCRATCH/hostile.env"
# SC2016: the $(...) here is literal test data, not a command substitution.
# shellcheck disable=SC2016
printf 'IFACE=$(touch %s/pwned)\n' "$SCRATCH" >"$EVIL_STATE"
# shellcheck disable=SC2016
assert_eq 'state parsing does not execute the file' \
  "$(printf '$(touch %s/pwned)' "$SCRATCH")" "$(state_get IFACE "$EVIL_STATE")"
if [[ -e "$SCRATCH/pwned" ]]; then
  ko 'a hostile state file has no side effect' 'the injected command ran'
else
  ok 'a hostile state file has no side effect'
fi

# ---------------------------------------------------------------------------
group 'client inventory: config parsing (unit)'
setup_render_env
PEER_CONF="$SCRATCH/peers.conf"
render_server_conf >"$PEER_CONF"
{
  printf '\n[Peer]\n# client: tablet\nPublicKey = %s\nAllowedIPs = 10.13.37.3/32\n' "$TEST_CLIENT_PUBKEY"
  printf '\n[Peer]\n# client: lab\nPublicKey = %s\nAllowedIPs = 10.13.37.4/32\n' "$TEST_SERVER_PUBKEY"
} >>"$PEER_CONF"

assert_eq 'conf_peers finds every peer' '3' "$(conf_peers "$PEER_CONF" | grep -c .)"
assert_eq 'conf_peers reports the client name' 'client' "$(conf_peers "$PEER_CONF" | sed -n 1p | cut -f1)"
assert_eq 'conf_peers reports the address without the mask' '10.13.37.2' \
  "$(conf_peers "$PEER_CONF" | sed -n 1p | cut -f2)"
assert_eq 'conf_peers reports the public key' "$TEST_CLIENT_PUBKEY" \
  "$(conf_peers "$PEER_CONF" | sed -n 1p | cut -f3)"
assert_eq 'conf_peers reads the last peer as well' 'lab' \
  "$(conf_peers "$PEER_CONF" | tail -1 | cut -f1)"
assert_eq 'conf_peers never reports the server address as a peer' '0' \
  "$(conf_peers "$PEER_CONF" | grep -c '10.13.37.1')"
assert_eq 'conf_peers on a config with no peers is empty' '' \
  "$(conf_peers "$SCRATCH/empty.conf" 2>/dev/null || true)"

KEPT="$(remove_peer "$PEER_CONF" tablet)"
assert_not_contains 'remove_peer drops the named peer' "$KEPT" 'tablet'
assert_contains 'remove_peer keeps the earlier peer' "$KEPT" 'client: client'
assert_contains 'remove_peer keeps the later peer' "$KEPT" 'client: lab'
assert_eq 'remove_peer keeps the interface section' '1' \
  "$(printf '%s\n' "$KEPT" | grep -c '^\[Interface\]')"
assert_eq 'remove_peer keeps exactly two peers' '2' "$(printf '%s\n' "$KEPT" | grep -c '^\[Peer\]')"
printf '%s\n' "$KEPT" >"$SCRATCH/kept.conf"
if [[ "$(id -u)" != 0 ]]; then
  printf '  skip (wg-quick re-execs through sudo; the strip check runs in the integration test)\n'
elif validate_wg_conf "$SCRATCH/kept.conf" wgm0; then
  ok 'the reduced config still passes wg-quick strip'
else
  ko 'the reduced config still passes wg-quick strip' "$(wg-quick strip "$SCRATCH/kept.conf" 2>&1 || true)"
fi

assert_eq 'humanize_age renders never for a zero timestamp' 'never' "$(humanize_age 0)"
assert_eq 'humanize_age renders a fresh handshake' 'just now' "$(humanize_age "$(date +%s)")"
assert_eq 'humanize_age renders minutes' '5m ago' "$(humanize_age "$(($(date +%s) - 300))")"

assert_eq 'conf_interface_privkey reads the server key' "$TEST_SERVER_PRIVKEY" \
  "$(conf_interface_privkey "$PEER_CONF")"
printf '[Peer]\nPublicKey = x\n' >"$SCRATCH/no-iface.conf"
if (conf_interface_privkey "$SCRATCH/no-iface.conf") >/dev/null 2>&1; then
  ko 'conf_interface_privkey refuses a config with no private key' 'expected non-zero status'
else
  ok 'conf_interface_privkey refuses a config with no private key'
fi

# ---------------------------------------------------------------------------
group 'client set: a repeat run must not re-key or drop anyone'
setup_render_env
EXISTING=$'client\t10.13.37.2\tPUBKEY_CLIENT\ntablet\t10.13.37.3\tPUBKEY_TABLET'

build_clients 1 "$EXISTING"
assert_eq 'a repeat run keeps every existing peer' '2' "${#CLIENT_NAMES[@]}"
assert_eq 'the existing client keeps its address' '10.13.37.2' "${CLIENT_ADDRS[0]}"
assert_eq 'the existing client keeps its public key' 'PUBKEY_CLIENT' "${CLIENT_PUBKEYS[0]}"
assert_eq 'a reused client is not marked as new' '0' "${CLIENT_IS_NEW[0]}"
assert_eq 'a reused client carries no private key, so no profile is rewritten' '0' \
  "$(printf '%s\n' "${CLIENT_PRIVKEYS[@]}" | grep -c .)"
assert_eq 'the reused count is reported' '2' "$(reused_client_count)"

# Naming rule, pinned here because it decides what "reused" means: --clients 1 is "client",
# --clients N>1 is client1..clientN.
build_clients 1 ""
assert_eq 'a first run with one client names it client' 'client' "${CLIENT_NAMES[*]}"
assert_eq 'a first run marks it as new' '1' "${CLIENT_IS_NEW[0]}"
assert_eq 'a first run has nothing reused' '0' "$(reused_client_count)"
assert_eq 'a first run starts at .2' '10.13.37.2' "${CLIENT_ADDRS[0]}"

build_clients 3 ""
assert_eq 'three clients are named client1..client3' 'client1 client2 client3' "${CLIENT_NAMES[*]}"

# Repeating the same command must add nobody...
build_clients 2 $'client1\t10.13.37.2\tPUB_A\nclient2\t10.13.37.3\tPUB_B'
assert_eq 'repeating --clients 2 keeps exactly those two' '2' "${#CLIENT_NAMES[@]}"
assert_eq 'repeating --clients 2 creates nothing new' '0' \
  "$((${#CLIENT_NAMES[@]} - $(reused_client_count)))"

# ...and growing the set adds only the missing name.
build_clients 2 $'client1\t10.13.37.2\tPUB_A'
assert_eq 'growing the client set keeps the existing peer' '2' "${#CLIENT_NAMES[@]}"
assert_eq 'the missing client is added at the next free address' '10.13.37.3' "${CLIENT_ADDRS[1]}"
assert_eq 'exactly one client is new' '1' "$((${#CLIENT_NAMES[@]} - $(reused_client_count)))"

# ---------------------------------------------------------------------------
group 'cli: client verbs refuse without root'
if [[ "$(id -u)" == 0 ]]; then
  printf '  skip (running as root)\n'
else
  maybe_run "$WGB" add-client tablet
  assert_eq 'add-client without root refuses' '1' "$RC"
  maybe_run "$WGB" remove-client client
  assert_eq 'remove-client without root refuses' '1' "$RC"
fi
maybe_run "$WGB" add-client
assert_eq 'add-client without a name is a usage error' '2' "$RC"
maybe_run "$WGB" add-client 'bad name!'
assert_eq 'a client name with spaces is a usage error' '2' "$RC"
maybe_run "$WGB" remove-client
assert_eq 'remove-client without a name is a usage error' '2' "$RC"
maybe_run "$WGB" qr
assert_eq 'qr without a name is a usage error' '2' "$RC"
maybe_run env WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$SCRATCH/out" "$WGB" qr no-such-client
assert_eq 'qr with no session fails' '1' "$RC"
assert_contains 'qr says there is no profile for that name' "$OUT" 'no profile for'
# The name builds a path, so it must not be able to express a traversal.
maybe_run env WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$SCRATCH/out" "$WGB" qr ../etc/shadow
assert_eq 'qr refuses a name containing a path' '2' "$RC"

# A plain `down` removes the state but KEEPS the profiles - `up` promises that. Printing one
# afterwards has to fall back to the newest profile directory under the output base.
QR_BASE="$SCRATCH/qrfallback"
mkdir -p "$QR_BASE/20260101T000000Z"
printf '[Interface]\nPrivateKey = x\n' >"$QR_BASE/20260101T000000Z/client.conf"
maybe_run env WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$QR_BASE" "$WGB" qr client
assert_eq 'qr finds a kept profile with no session state' '0' "$RC"
assert_contains 'and says which directory it fell back to' "$OUT" "$QR_BASE/20260101T000000Z"
maybe_run env WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$QR_BASE" "$WGB" qr tablet
assert_eq 'an unknown name in a kept directory still fails' '1' "$RC"
assert_contains 'and the error lists the profiles that do exist' "$OUT" \
  'Profiles that do exist: client'
maybe_run env WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$SCRATCH/emptybase" "$WGB" qr client
assert_eq 'qr with no session and no profiles fails' '1' "$RC"
assert_contains 'and names the directory it looked in' "$OUT" "$SCRATCH/emptybase"

# Profiles must stay findable from another directory and after the state is gone: bring-up records
# where it wrote them, so a later session (or cwd) can still find them.
IDX_A="$SCRATCH/idx/a/20260101T000000Z"
IDX_B="$SCRATCH/idx/b/20260102T000000Z"
mkdir -p "$IDX_A" "$IDX_B"
printf '[Interface]\nPrivateKey = x\n' >"$IDX_A/client.conf"
printf '[Interface]\nPrivateKey = x\n' >"$IDX_B/tablet.conf"
record_profile_dir "$IDX_A"
record_profile_dir "$IDX_B"
assert_eq 'the index lists directories newest first' "$IDX_B $IDX_A" \
  "$(recorded_profile_dirs | tr '\n' ' ' | sed 's/ $//')"
record_profile_dir "$IDX_A"
assert_eq 're-recording a directory makes it the newest, without duplicating it' "$IDX_A $IDX_B" \
  "$(recorded_profile_dirs | tr '\n' ' ' | sed 's/ $//')"
assert_eq 'a profile in an older directory is still found' "$IDX_A" "$(find_profile_for client)"
printf '[Interface]\nPrivateKey = x\n' >"$IDX_B/client.conf"
OUTDIR="$IDX_B"
assert_eq 'the session directory wins when it has the name too' "$IDX_B" "$(find_profile_for client)"
OUTDIR=""
assert_eq 'a name that exists nowhere is reported as not found' '1' \
  "$(find_profile_for nosuch >/dev/null 2>&1 && printf 0 || printf 1)"

maybe_run env -C "$SCRATCH" WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$SCRATCH/elsewhere" \
  WGB_INDEX_DIR="$INDEX_DIR" "$WGB" qr client
assert_eq 'qr finds a recorded profile from any directory' '0' "$RC"
assert_contains 'and reports which directory it used' "$OUT" "$IDX_A"

# A peer that is in the config but whose profile is nowhere: its private key cannot be recovered, so
# the message must say that instead of pretending the name is wrong.
LOST_ETC="$SCRATCH/lostetc"
mkdir -p "$LOST_ETC"
setup_render_env
render_server_conf >"$LOST_ETC/wgm0.conf"
maybe_run env -C "$SCRATCH" WGB_STATE_DIR="$SCRATCH/none" WGB_OUT_BASE="$SCRATCH/void" \
  WGB_INDEX_DIR="$SCRATCH/index-lost" WGB_ETC_DIR="$LOST_ETC" "$WGB" qr client
assert_eq 'qr fails for a peer whose profile is lost' '1' "$RC"
assert_contains 'and says the key exists only in that file' "$OUT" 'exists only in its profile file'
assert_contains 'and gives the remedy' "$OUT" 'give it a new one'
assert_eq 'qr does not create an output directory while looking' 'no' \
  "$([[ -e "$SCRATCH/out" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'every verb is implemented (no stubs left)'
maybe_run "$WGB" ca
assert_eq 'ca is implemented and exits 0' '0' "$RC"
assert_contains 'ca explains the Android 7+ user-store limitation' "$OUT" 'networkSecurityConfig'
assert_contains 'ca explains the iOS trust step' "$OUT" 'Certificate Trust Settings'
assert_contains 'ca says how to verify before trusting a finding' "$OUT" 'http://burp'
assert_contains 'ca covers pinning' "$OUT" 'Frida'
assert_contains 'ca decodes the client-side TLS alert' "$OUT" 'certificate_unknown'
assert_contains 'and says the alert comes from the client, not the proxy' "$OUT" 'the CLIENT refused the proxy certificate'
if [[ "$(id -u)" == 0 ]]; then
  printf '  skip (running as root: the wait refusal cannot be exercised)\n'
else
  maybe_run "$WGB" wait
  assert_eq 'wait needs root and says so' '1' "$RC"
  assert_contains 'the wait refusal names the fix' "$OUT" 'sudo'
fi
# wait does not run the shared validation, so it checks its own timeout: a bare word would be read
# as an unset variable in the arithmetic and turn into "wait 0 seconds".
maybe_run "$WGB" wait --timeout abc
assert_eq 'a non-numeric --timeout is a usage error for wait too' '2' "$RC"

# ---------------------------------------------------------------------------
group 'cli: help'
maybe_run "$WGB" --help
assert_eq 'help exits 0' '0' "$RC"
assert_contains 'help documents the intercept flags' "$OUT" '--no-proxy'
assert_contains 'help lists the client-facing verbs' "$OUT" 'add-client'
maybe_run "$WGB" version
assert_eq 'version exits 0' '0' "$RC"
assert_eq 'version prints the version' "$PROG $WGB_VERSION" "$OUT"

# ---------------------------------------------------------------------------
test_summary || exit 1
