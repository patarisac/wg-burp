#!/usr/bin/env bash
#
# Integration test: a real bring-up / teardown cycle, run inside a throwaway network
# namespace so this host's interfaces, routing and firewall are never touched.
#
# This is the test a dry run cannot replace. It is the regression test for the class of
# bug the old generator had: rules that stack on a second bring-up, a table that survives
# teardown, forwarding forced back to 0 after a session.
#
#   sudo ./test/integration-netns.sh
#
# Needs root (network namespace + nft + wireguard-tools). Without root it reports
# "skipped" and exits 0, so CI on an unprivileged runner stays green.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
WGB="$ROOT/wgb"

NETNS="wgb-integration"
IFACE="wgbi0"
PROXY_PORT="8083"
WORK="$(mktemp -d)"
# Same reason as the unit suite: never touch the real profile index from a test.
export WGB_INDEX_DIR="$WORK/index"
# mktemp -d gives 700 root. Left that way, an operator-access assertion would fail on the
# harness's own permissions instead of the tool's, so make the tree traversable and let the
# tool's directories be the only thing under test.
chmod 711 "$WORK"

if [[ "$(id -u)" != 0 ]]; then
  printf 'skipped: this test needs root (namespace, nft, wireguard-tools).\n'
  printf 'run it as: sudo %s\n' "$0"
  exit 0
fi

# shellcheck source=lib.sh
source "$ROOT/test/lib.sh"

have_ns_tooling() {
  command -v ip >/dev/null 2>&1 && command -v nft >/dev/null 2>&1 &&
    command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1
}
have_ns_tooling || {
  printf 'skipped: ip netns, nft or wg-quick unavailable on this host.\n'
  exit 0
}

# A missing wireguard KERNEL module is the one capability that cannot be inferred from the tools being
# installed: wg and wg-quick are user space, and the interface can still refuse to exist. The honest
# check is to create one, in a throwaway namespace, before the suite spends minutes on setup - runners
# and containers that ship wireguard-tools without the module then get a clean skip instead of a
# cascade of failures that look like bugs in the tool.
have_wireguard() {
  local ns=wgb_wgprobe rc=0
  ip netns add "$ns" 2>/dev/null || return 1
  ip netns exec "$ns" ip link add dev wgprobe type wireguard 2>/dev/null || rc=1
  ip netns del "$ns" 2>/dev/null || true
  return $rc
}
have_wireguard || {
  printf 'skipped: the wireguard kernel module is not available on this host.\n'
  printf 'wireguard-tools can be installed without it (a container or a cloud kernel often is).\n'
  exit 0
}

# The operator is whoever invoked the suite. The tool chowns its output to $SUDO_USER, so the
# ownership assertions must name a user that exists HERE: hardcoding one made the suite fail on any
# machine without that account (a CI runner, another developer's box).
OP_USER="${SUDO_USER:-$(id -un)}"
if ! id "$OP_USER" >/dev/null 2>&1; then
  OP_USER="$(id -un)"
fi

cleanup() {
  if [[ -n "${LOOPBACK_PID:-}" ]]; then kill "$LOOPBACK_PID" 2>/dev/null || true; fi
  ip netns exec "$NETNS" nft delete table inet wgb 2>/dev/null || true
  ip netns del "$NETNS" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# wgb, run inside the namespace, with its state/config/output redirected into $WORK so
# nothing on the host filesystem is written.
wgb() {
  ip netns exec "$NETNS" env \
    WGB_STATE_DIR="$WORK/run" WGB_ETC_DIR="$WORK/etc" WGB_OUT_BASE="$WORK/out" \
    "$WGB" "$@"
}
ns() { ip netns exec "$NETNS" "$@"; }
ns_forwarding() { ns sysctl -n net.ipv4.ip_forward 2>/dev/null; }
# Counter stats change as packets flow, so they are stripped here: this suite asserts rule IDENTITY
# (byte-identical after a second up), and the end-to-end suite is what asserts the counters count.
ns_snapshot() { ns nft list table inet wgb 2>/dev/null | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/'; }
ns_has_table() { ns nft list table inet wgb >/dev/null 2>&1; }
ns_has_iface() { ns ip link show dev "$IFACE" >/dev/null 2>&1; }
state_path() { printf '%s/run/%s.env' "$WORK" "$IFACE"; }
conf_path() { printf '%s/etc/%s.conf' "$WORK" "$IFACE"; }

UP_ARGS=(up "--iface=$IFACE" --endpoint 192.0.2.10 --wan lo)

printf 'integration test: real up/down cycle in namespace %s\n' "$NETNS"

if ! ip netns add "$NETNS" 2>/dev/null; then
  printf 'skipped: could not create network namespace %s\n' "$NETNS"
  exit 0
fi
ns ip link set lo up
ns ip -4 addr add 192.0.2.1/32 dev lo 2>/dev/null || true

# ---------------------------------------------------------------------------
group 'ruleset syntax: validated by nft, not by a golden file'
# A golden fixture cannot tell you whether the ruleset parses - it only proves the text
# did not change. This is the assertion that catches an invalid expression.
maybe_run wgb up "--iface=$IFACE" --endpoint 192.0.2.10 --wan lo --print-rules
assert_eq 'print-rules exits 0 without changing anything' '0' "$RC"
# Keep the ruleset: the next maybe_run overwrites OUT.
RULESET="$OUT"
printf '%s\n' "$RULESET" >"$WORK/ruleset.nft"
maybe_run ns nft -c -f "$WORK/ruleset.nft"
assert_eq 'nft accepts the generated ruleset' '0' "$RC"
assert_not_contains 'the ruleset avoids the reserved chain name fwd' "$RULESET" 'chain fwd {'
assert_contains 'the TCP redirect uses meta l4proto' "$RULESET" 'meta l4proto tcp counter redirect to :8083'

# Set a non-default starting point on purpose: this is what a machine that already
# forwards traffic for something else looks like.
ns sysctl -qw net.ipv4.ip_forward=1
PRE_EXISTING_FORWARD="$(ns_forwarding)"

# ---------------------------------------------------------------------------
group 'bring-up'
maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'up succeeds' '0' "$RC"
assert_contains 'up reports the tunnel' "$OUT" 'tunnel is up'
assert_eq 'the interface exists in the namespace' 'yes' "$(ns_has_iface && printf yes || printf no)"
assert_eq 'the nft table was loaded' 'yes' "$(ns_has_table && printf yes || printf no)"
assert_eq 'server config mode is 0600' '600' "$(stat -c '%a' "$(conf_path)" 2>/dev/null)"
assert_eq 'client profile mode is 0600' '600' "$(stat -c '%a' "$WORK/out"/*/client.conf 2>/dev/null)"
assert_eq 'session state mode is 0600' '600' "$(stat -c '%a' "$(state_path)" 2>/dev/null)"
assert_eq 'forwarding is enabled inside the namespace' '1' "$(ns_forwarding)"
assert_eq 'the pre-existing forwarding value was recorded' "$PRE_EXISTING_FORWARD" \
  "$(grep -m1 '^PRIOR_IP_FORWARD=' "$(state_path)" | cut -d= -f2-)"

SNAP_1="$(ns_snapshot)"
assert_contains 'rules redirect TCP to the proxy port' "$SNAP_1" 'redirect to :8083'
assert_contains 'rules drop QUIC by default' "$SNAP_1" 'udp dport 443 counter drop'
assert_contains 'rules masquerade the tunnel subnet' "$SNAP_1" 'masquerade'
assert_eq 'the TCP redirect appears exactly once' '1' \
  "$(printf '%s\n' "$SNAP_1" | grep -c 'redirect to :8083')"

# ---------------------------------------------------------------------------
group 'second bring-up reconciles instead of stacking'
maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'second up succeeds' '0' "$RC"
assert_contains 'second up syncs instead of restarting the link' "$OUT" 'syncing peers'
SNAP_2="$(ns_snapshot)"
assert_eq 'the ruleset is byte-identical after a second up' "$SNAP_1" "$SNAP_2"

# ---------------------------------------------------------------------------
group 'teardown restores the machine'
maybe_run wgb down "--iface=$IFACE"
assert_eq 'down succeeds' '0' "$RC"
assert_eq 'the interface is gone' 'no' "$(ns_has_iface && printf yes || printf no)"
assert_eq 'the nft table is gone' 'no' "$(ns_has_table && printf yes || printf no)"
assert_eq 'session state is gone' 'no' "$([[ -e "$(state_path)" ]] && printf yes || printf no)"
assert_eq 'forwarding is restored to the pre-existing value (not forced to 0)' \
  "$PRE_EXISTING_FORWARD" "$(ns_forwarding)"
assert_eq 'the server config is kept for reference' 'yes' \
  "$([[ -e "$(conf_path)" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'up / down / up leaves an identical ruleset'
maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'third bring-up succeeds' '0' "$RC"
SNAP_3="$(ns_snapshot)"
assert_eq 'the ruleset matches the first bring-up byte for byte' "$SNAP_1" "$SNAP_3"
maybe_run wgb down "--iface=$IFACE"
assert_eq 'teardown after the third cycle succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'flag wiring survives the real path'
maybe_run wgb up "--iface=$IFACE" --endpoint 192.0.2.10 --wan lo --no-proxy
assert_eq 'up --no-proxy succeeds' '0' "$RC"
assert_not_contains '--no-proxy installs no TCP redirect' "$(ns_snapshot)" 'redirect to :'
maybe_run wgb down "--iface=$IFACE"
assert_eq 'teardown succeeds' '0' "$RC"

maybe_run wgb up "--iface=$IFACE" --endpoint 192.0.2.10 --wan lo --allow-quic --mtu 1280
assert_eq 'up --allow-quic succeeds' '0' "$RC"
# Deliberately without the `counter` keyword: this must fail if the rule is present in ANY form.
assert_not_contains '--allow-quic installs no UDP 443 drop' "$(ns_snapshot)" 'udp dport 443'
assert_contains 'the requested MTU reaches the server config' "$(cat "$(conf_path)")" 'MTU = 1280'
assert_eq 'the requested MTU is applied to the live interface' '1280' \
  "$(ns ip -o link show dev "$IFACE" | sed -E 's/.*mtu ([0-9]+).*/\1/')"
maybe_run wgb down "--iface=$IFACE" --purge
assert_eq 'down --purge succeeds' '0' "$RC"
assert_eq '--purge removes the server config' 'no' \
  "$([[ -e "$(conf_path)" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'client management on a live tunnel'
has_profile() { compgen -G "$WORK/out/*/$1.conf" >/dev/null 2>&1 && printf yes || printf no; }
profile_count() { ns wg show "$IFACE" peers 2>/dev/null | wc -l | tr -d ' '; }

maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'bring-up for the client tests succeeds' '0' "$RC"
assert_eq 'the tunnel starts with one peer' '1' "$(profile_count)"

maybe_run wgb list
assert_eq 'list exits 0' '0' "$RC"
assert_contains 'list shows the initial peer' "$OUT" 'client'
assert_contains 'list counts the peers' "$OUT" '1 peer(s)'

maybe_run wgb add-client tablet
assert_eq 'add-client succeeds' '0' "$RC"
assert_contains 'add-client reports the allocated address' "$OUT" '10.13.37.3/32'
assert_eq 'the live interface now carries two peers' '2' "$(profile_count)"
assert_eq 'the new profile was written' 'yes' "$(has_profile tablet)"
assert_eq 'the new profile mode is 0600' '600' \
  "$(stat -c '%a' "$(compgen -G "$WORK/out/*/tablet.conf" | head -1)")"
# The profile has to be IMPORTABLE, not merely present: rendering without the session's resolved
# values produced `PublicKey = ` and `Endpoint = :51820`, which every client app rejects with
# "syntax error in Peer". Asserting only that a file appeared is what let that through.
NEW_PROFILE="$(compgen -G "$WORK/out/*/tablet.conf" | head -1)"
assert_eq 'the new profile dials the key the tunnel actually uses' \
  "$(ns wg show "$IFACE" public-key)" \
  "$(awk -F' = ' '/^PublicKey/ { print $2; exit }' "$NEW_PROFILE")"
assert_eq 'the new profile dials the session endpoint and port' \
  "$(grep -m1 '^ENDPOINT=' "$(state_path)" | cut -d= -f2-):51820" \
  "$(awk -F' = ' '/^Endpoint/ { print $2; exit }' "$NEW_PROFILE")"
assert_eq 'it is not the malformed shape the app rejects' '0' \
  "$(grep -c '^PublicKey = $\|^Endpoint = :[0-9]' "$NEW_PROFILE" || true)"

maybe_run wgb list
assert_contains 'list shows the added peer' "$OUT" 'tablet'
assert_contains 'list counts both peers' "$OUT" '2 peer(s)'

maybe_run wgb add-client tablet
assert_eq 'a duplicate client name is refused' '1' "$RC"
assert_contains 'the duplicate refusal explains itself' "$OUT" 'already exists'

maybe_run wgb remove-client tablet
assert_eq 'remove-client succeeds' '0' "$RC"
assert_eq 'the live interface is back to one peer' '1' "$(profile_count)"
assert_eq 'the removed profile is gone' 'no' "$(has_profile tablet)"

maybe_run wgb remove-client tablet
assert_eq 'removing an unknown client fails' '1' "$RC"
assert_contains 'the unknown-client error says where to look' "$OUT" 'list'
# A profile left behind for a peer that no longer exists is a trap: it imports, and the handshake can
# never complete. It must be gone from EVERY directory we search, not only this session's.
assert_eq 'no stale profile survives the removal, in any directory' '0' \
  "$(compgen -G "$WORK"/out*/*/tablet.conf | wc -l | tr -d ' ')"
maybe_run wgb qr tablet
assert_eq 'qr refuses a profile whose peer was removed' '1' "$RC"
assert_contains 'and says why the profile on disk is stale' "$OUT" 'is stale'
# remove-client rewrites the whole config. It must do that without leaving a working copy behind
# (which would be a second file holding the server private key, and a leftover after a crash).
assert_eq 'no working copy of the config is left in the config directory' '0' \
  "$(find "$WORK/etc" -maxdepth 1 \( -name '*.removing*' -o -name '.*' \) | wc -l | tr -d ' ')"

maybe_run wgb list
assert_contains 'the original peer was never disturbed' "$OUT" 'client'
assert_eq 'still exactly one live peer' '1' "$(profile_count)"

# A reload must not resurrect or duplicate anything.
maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'bring-up after client churn succeeds' '0' "$RC"
assert_eq 'the peer count is still one' '1' "$(profile_count)"
maybe_run wgb down "--iface=$IFACE"
assert_eq 'teardown after client churn succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'wait: handshake detection and the timeout playbook'
maybe_run wgb up "${UP_ARGS[@]}"
assert_eq 'bring-up for the wait tests succeeds' '0' "$RC"
maybe_run wgb wait --timeout 2
assert_eq 'wait fails when no client connects' '1' "$RC"
assert_contains 'wait reports the timeout' "$OUT" 'no handshake after 2s'
assert_contains 'the playbook is ordered by likelihood' "$OUT" 'ordered by how often'
assert_contains 'the playbook names UDP filtering' "$OUT" 'filtering UDP 51820'
assert_contains 'the playbook names Private DNS' "$OUT" 'Private DNS'
assert_contains 'the playbook points at doctor' "$OUT" 'doctor'
maybe_run wgb down "--iface=$IFACE"
assert_eq 'teardown after the wait tests succeeds' '0' "$RC"
maybe_run wgb wait --timeout 2
assert_eq 'wait on a down tunnel fails' '1' "$RC"
assert_contains 'wait says which interface is not up' "$OUT" 'is not up'

# ---------------------------------------------------------------------------
group 'a repeat up reuses the session instead of re-keying it'
maybe_run wgb up "${UP_ARGS[@]}"
assert_eq 'first bring-up for the reuse tests succeeds' '0' "$RC"
maybe_run wgb add-client tablet
assert_eq 'a client is added before the repeat run' '0' "$RC"
KEY_BEFORE="$(grep -m1 '^PrivateKey' "$(conf_path)")"
PEER_BEFORE="$(grep -A2 'client: client' "$(conf_path)" | grep -m1 '^PublicKey')"
assert_eq 'two peers are live before the repeat run' '2' "$(profile_count)"

maybe_run wgb up "${UP_ARGS[@]}"
assert_eq 'a repeat up succeeds' '0' "$RC"
assert_contains 'the repeat up says it reused the existing keys' "$OUT" 'reusing the server key'
assert_eq 'the server key is unchanged by a repeat run' "$KEY_BEFORE" \
  "$(grep -m1 '^PrivateKey' "$(conf_path)")"
assert_eq 'the existing client is not re-keyed' "$PEER_BEFORE" \
  "$PEER_BEFORE"
assert_contains 'the peer added earlier survives the repeat run' "$(cat "$(conf_path)")" 'client: tablet'
assert_eq 'both peers are still live after the repeat run' '2' "$(profile_count)"

# --fresh is the old behaviour, and it must announce the damage it does.
maybe_run wgb up "${UP_ARGS[@]}" --fresh
assert_eq 'up --fresh succeeds' '0' "$RC"
assert_contains 'up --fresh warns that imported profiles break' "$OUT" 'will stop working'
assert_eq 'up --fresh leaves only the peers it was asked for' '1' "$(profile_count)"
maybe_run wgb down "--iface=$IFACE" --purge
assert_eq 'teardown after the reuse tests succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'doctor catches a proxy bound to loopback (the blackhole trap)'
maybe_run wgb up "${UP_ARGS[@]}"
assert_eq 'bring-up for the doctor test succeeds' '0' "$RC"
# A listener on the proxy port bound to 127.0.0.1 only: the redirect rewrites the
# destination to the tunnel address, so this listener receives nothing at all.
ns python3 -m http.server "$PROXY_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
LOOPBACK_PID=$!
sleep 1
maybe_run wgb doctor --endpoint 192.0.2.10 --wan lo
assert_eq 'doctor fails when the proxy is loopback-only' '1' "$RC"
assert_contains 'doctor explains the blackhole' "$OUT" 'redirected traffic is blackholed'
assert_contains 'doctor names the address to rebind to' "$OUT" '0.0.0.0'
# A failing doctor must still finish its report: an rc-only assertion passes even when the tool
# dies early (which is exactly what set -e did here once), so assert the closing line too.
assert_contains 'doctor reaches the end of its report' "$OUT" 'blocking problems found'
assert_contains 'doctor sees no competing forward chain yet' "$OUT" 'only forward chain'

# Another table with a forward-hook DROP policy: an nft accept is not terminal across base
# chains, so this is the configuration that silently drops tunnel traffic.
ns nft add table inet otherfw
ns nft 'add chain inet otherfw otherfw_forward { type filter hook forward priority filter; policy drop; }'
maybe_run wgb doctor --endpoint 192.0.2.10 --wan lo
assert_contains 'doctor names the competing table' "$OUT" 'inet otherfw'
assert_contains 'doctor explains why an accept does not save you' "$OUT" \
  'NOT terminal across base chains'
# The policy is what matters, and the operator needs the exact remedy: this is the condition that
# produces "handshake fine, client has no internet" while everything in this tool reports success.
assert_contains 'doctor reports the other chain policy as DROP' "$OUT" 'has policy DROP'
assert_contains 'doctor names the fix for it' "$OUT" 'fix:'
maybe_run wgb "${UP_ARGS[@]}"
assert_eq 'a repeat up still succeeds' '0' "$RC"
assert_contains 'up warns that another firewall drops forwarded packets' "$OUT" \
  'another firewall drops forwarded packets'
assert_contains 'and names the subnet to allow there' "$OUT" 'allow 10.13.37.0/24 there'
ns nft delete table inet otherfw
maybe_run wgb doctor --endpoint 192.0.2.10 --wan lo
assert_contains 'and goes quiet again once it is gone' "$OUT" 'only forward chain'
kill "$LOOPBACK_PID" 2>/dev/null || true
wait "$LOOPBACK_PID" 2>/dev/null || true
maybe_run wgb down "--iface=$IFACE"
assert_eq 'teardown after the doctor test succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'defaults: interface name and operator ownership'
maybe_run ns env SUDO_USER="$OP_USER" WGB_STATE_DIR="$WORK/run2" WGB_ETC_DIR="$WORK/etc2" \
  WGB_OUT_BASE="$WORK/out2" "$WGB" up --endpoint 192.0.2.10 --wan lo
assert_eq 'up with no --iface succeeds' '0' "$RC"
assert_eq 'the default interface name is used' 'yes' \
  "$(ns ip link show dev wgm0 >/dev/null 2>&1 && printf yes || printf no)"
CUR_OUT2="$(grep -m1 '^OUTDIR=' "$WORK/run2/wgm0.env" | cut -d= -f2-)"
assert_eq 'the session recorded its output directory' 'yes' \
  "$([[ -n "$CUR_OUT2" ]] && printf yes || printf no)"
assert_eq 'the profile belongs to the invoking user, not root' "$OP_USER" \
  "$(stat -c '%U' "$CUR_OUT2/client.conf" 2>/dev/null)"
# Ownership of the file is not enough: a root-owned 700 directory means the operator cannot
# enter it to read their own profile, push it to a client, or open the QR image.
assert_eq 'the profile directory belongs to the invoking user too' "$OP_USER" \
  "$(stat -c '%U' "$CUR_OUT2" 2>/dev/null)"
assert_eq 'the profile is not readable by other users' '600' \
  "$(stat -c '%a' "$CUR_OUT2/client.conf" 2>/dev/null)"
if command -v runuser >/dev/null 2>&1 && id "$OP_USER" >/dev/null 2>&1 && [[ "$OP_USER" != root ]]; then
  assert_eq 'the operator can read their profile as themselves' 'read' \
    "$(runuser -u "$OP_USER" -- cat "$CUR_OUT2/client.conf" >/dev/null 2>&1 && printf read || printf denied)"
  assert_eq 'the operator can list their own output directory' 'listed' \
    "$(runuser -u "$OP_USER" -- ls "$CUR_OUT2" >/dev/null 2>&1 && printf listed || printf denied)"
else
  printf '  skip (runuser, or a non-root operator user, is unavailable on this runner)\n'
fi
maybe_run ns env SUDO_USER="$OP_USER" WGB_STATE_DIR="$WORK/run2" WGB_ETC_DIR="$WORK/etc2" \
  WGB_OUT_BASE="$WORK/out2" "$WGB" down
assert_eq 'teardown of the default-named interface succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'multiple clients and a PNG QR (never exercised before)'
maybe_run wgb up "${UP_ARGS[@]}" --clients 2
assert_eq 'up --clients 2 succeeds' '0' "$RC"
# --clients 2 asks for client1 and client2, so the single-client session's "client" peer from
# the earlier group is kept rather than replaced: nothing working is ever silently dropped.
assert_eq 'the earlier peer is kept alongside the two new ones' '3' "$(profile_count)"
assert_contains 'up names the peer it kept from the previous session' "$OUT" \
  'kept from the previous session'
assert_contains 'up tells you how to remove it' "$OUT" 'remove-client'
# Scope to the directory this session recorded: earlier groups left their own out/ dirs.
CUR_OUT="$(grep -m1 '^OUTDIR=' "$(state_path)" | cut -d= -f2-)"
assert_eq 'the session recorded an output directory' 'yes' \
  "$([[ -n "$CUR_OUT" ]] && printf yes || printf no)"
assert_eq 'two profiles were written in it' '2' \
  "$(compgen -G "$CUR_OUT/client*.conf" | wc -l | tr -d ' ')"
assert_eq 'the profiles are named client1 and client2' 'client1.conf client2.conf' \
  "$(compgen -G "$CUR_OUT/client*.conf" | sed 's|.*/||' | sort | tr '\n' ' ' | sed 's/ $//')"

maybe_run wgb qr client1 --png
assert_eq 'qr --png succeeds' '0' "$RC"
PNG="$CUR_OUT/client1.conf.png"
assert_eq 'a PNG was written next to the profile' 'yes' \
  "$([[ -e "$PNG" ]] && printf yes || printf no)"
if [[ -e "$PNG" ]]; then
  assert_eq 'the PNG is a real image file' 'PNG' "$(file -b "$PNG" | cut -d' ' -f1)"
  # The PNG encodes the private key, and qrencode honours the umask: without an explicit chmod
  # this file is created world-readable.
  assert_eq 'the PNG holding the private key is 0600' '600' "$(stat -c '%a' "$PNG" 2>/dev/null)"
  assert_eq 'and it belongs to the operator' "${SUDO_USER:-root}" \
    "$(stat -c '%U' "$PNG" 2>/dev/null)"
else
  ko 'the PNG is a real image file' 'no PNG was written'
fi
maybe_run wgb down "--iface=$IFACE" --purge
assert_eq 'teardown after the multi-client test succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'a missing config directory is created like the package does'
# wireguard-tools ships /etc/wireguard as 0700 root:root and wg-quick never creates it. If the
# tool ever has to, it must not leave a directory created with the ambient umask.
maybe_run ns env WGB_STATE_DIR="$WORK/run3" WGB_ETC_DIR="$WORK/missing/nested/etc" \
  WGB_OUT_BASE="$WORK/out3" "$WGB" up --endpoint 192.0.2.10 --wan lo
assert_eq 'up creates the directory it needs' '0' "$RC"
assert_eq 'the directory is 0700, as the package ships it' '700' \
  "$(stat -c '%a' "$WORK/missing/nested/etc" 2>/dev/null)"
assert_eq 'the server config inside it is 0600' '600' \
  "$(stat -c '%a' "$WORK/missing/nested/etc/wgm0.conf" 2>/dev/null)"
maybe_run ns env WGB_STATE_DIR="$WORK/run3" WGB_ETC_DIR="$WORK/missing/nested/etc" \
  WGB_OUT_BASE="$WORK/out3" "$WGB" down --purge
assert_eq 'teardown of that session succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'the real /etc/wireguard path, with no override'
# Everything else in this file redirects the config directory; this group deliberately does not.
# It exercises the default path, the backup behaviour and the cleanup against the real
# /etc/wireguard, using a distinct interface name and removing every file it creates.
REAL_CONF="/etc/wireguard/wgbint0.conf"
# An interrupted earlier run can leave files here (which is exactly how this was noticed). Clear
# them first so the counts below mean what they say, and so this group heals the host it touches.
LEFTOVERS="$(compgen -G "/etc/wireguard/wgbint*" || true)"
if [[ -n "$LEFTOVERS" ]]; then
  printf '  ..   clearing files an earlier run left in /etc/wireguard: %s\n' \
    "$(printf '%s' "$LEFTOVERS" | tr '\n' ' ')"
  rm -f /etc/wireguard/wgbint*
fi
assert_eq 'the package-provided config directory exists' 'yes' \
  "$([[ -d /etc/wireguard ]] && printf yes || printf no)"
assert_eq 'and it is root-only, as wireguard-tools ships it' '700' "$(stat -c '%a' /etc/wireguard)"
# Only the *config* directory is left at its default here; the state and output directories stay
# redirected so the test does not litter the working tree it runs from.
maybe_run ns env WGB_STATE_DIR="$WORK/run4" WGB_OUT_BASE="$WORK/out4" \
  "$WGB" up --iface=wgbint0 --endpoint 192.0.2.10 --wan lo
assert_eq 'up against the default config directory succeeds' '0' "$RC"
assert_eq 'the config landed in /etc/wireguard' 'yes' \
  "$([[ -e "$REAL_CONF" ]] && printf yes || printf no)"
assert_eq 'the config is 0600' '600' "$(stat -c '%a' "$REAL_CONF" 2>/dev/null)"
assert_eq 'the link exists in the namespace' 'yes' \
  "$(ns ip link show dev wgbint0 >/dev/null 2>&1 && printf yes || printf no)"

maybe_run ns env WGB_STATE_DIR="$WORK/run4" WGB_OUT_BASE="$WORK/out4" \
  "$WGB" up --iface=wgbint0 --endpoint 192.0.2.10 --wan lo
assert_eq 'a repeat up against the real path succeeds' '0' "$RC"
assert_contains 'the previous file was backed up' "$OUT" 'backed up'
assert_eq 'exactly one backup was made' '1' \
  "$(compgen -G "/etc/wireguard/wgbint0.conf.bak-*" | wc -l | tr -d ' ')"

maybe_run ns env WGB_STATE_DIR="$WORK/run4" "$WGB" down --iface=wgbint0 --purge
assert_eq 'down --purge against the real path succeeds' '0' "$RC"
assert_eq 'the config is gone' 'no' "$([[ -e "$REAL_CONF" ]] && printf yes || printf no)"
assert_eq 'the backup is gone too, so no key material is left behind' '0' \
  "$(compgen -G "/etc/wireguard/wgbint0*" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
group 'a session started with --config-dir is manageable without repeating it'
CUSTOM_DIR="$WORK/etc4"
maybe_run ns env WGB_STATE_DIR="$WORK/run5" WGB_OUT_BASE="$WORK/out5" "$WGB" up --iface=wgbint1 \
  --config-dir="$CUSTOM_DIR" --endpoint 192.0.2.10 --wan lo
assert_eq 'up with --config-dir succeeds' '0' "$RC"
assert_eq 'the config landed in the chosen directory' 'yes' \
  "$([[ -e "$CUSTOM_DIR/wgbint1.conf" ]] && printf yes || printf no)"
maybe_run ns env WGB_STATE_DIR="$WORK/run5" WGB_OUT_BASE="$WORK/out5" "$WGB" list
assert_contains 'list finds it by adopting the session directory' "$OUT" "wgbint1.conf"
maybe_run ns env WGB_STATE_DIR="$WORK/run5" WGB_OUT_BASE="$WORK/out5" "$WGB" down --purge
assert_eq 'down without --config-dir still tears that session down' '0' "$RC"
assert_eq 'the chosen config is gone' 'no' \
  "$([[ -e "$CUSTOM_DIR/wgbint1.conf" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'the default output directory, from a scratch working directory'
# OUT_BASE defaults to $PWD/out. Run the tool with a scratch cwd so the default is exercised
# without dropping a directory into the tree the tests live in.
mkdir -p "$WORK/cwdtest"
maybe_run ns env -C "$WORK/cwdtest" WGB_STATE_DIR="$WORK/run6" WGB_ETC_DIR="$WORK/etc6" \
  "$WGB" up --iface=wgbint2 --endpoint 192.0.2.10 --wan lo
assert_eq 'up with no output override succeeds' '0' "$RC"
assert_contains 'up reports the default output directory' "$OUT" "$WORK/cwdtest/out"
assert_eq 'the profile landed in <cwd>/out as documented' 'yes' \
  "$([[ -n "$(compgen -G "$WORK/cwdtest/out/*/client.conf")" ]] && printf yes || printf no)"
maybe_run ns env -C "$WORK/cwdtest" WGB_STATE_DIR="$WORK/run6" WGB_ETC_DIR="$WORK/etc6" \
  "$WGB" down --purge
assert_eq 'teardown of that session succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'an unclean kill mid-bring-up still leaves a teardown path'
# `up` records what teardown needs before it changes anything. Kill it as soon as the state file
# appears and then require `down` to restore the machine: the failure this guards against is a
# host left with forwarding enabled and no record of the value to put back.
KILL_DIR="$WORK/run8"
FWD_BEFORE_CRASH="$(ns_forwarding)"
ns env WGB_STATE_DIR="$KILL_DIR" WGB_ETC_DIR="$WORK/etc8" WGB_OUT_BASE="$WORK/out8" \
  "$WGB" up --iface=wgbi8 --endpoint 192.0.2.10 --wan lo >"$WORK/killed.log" 2>&1 &
KILL_PID=$!
for _ in $(seq 1 100); do
  [[ -e "$KILL_DIR/wgbi8.env" ]] && break
  sleep 0.1
done
if kill -0 "$KILL_PID" 2>/dev/null; then
  ok 'the bring-up was still running when the state was recorded'
else
  printf '  ..   the bring-up finished before the kill on this machine; the invariant below still applies\n'
fi
kill -9 "$KILL_PID" 2>/dev/null || true
wait "$KILL_PID" 2>/dev/null || true
sleep 1 # let any orphaned helper finish before judging what was left behind

assert_eq 'the state file exists even though the bring-up was killed' 'yes' \
  "$([[ -e "$KILL_DIR/wgbi8.env" ]] && printf yes || printf no)"
assert_contains 'it records the forwarding value teardown must restore' \
  "$(cat "$KILL_DIR/wgbi8.env" 2>/dev/null)" "PRIOR_IP_FORWARD=$FWD_BEFORE_CRASH"
maybe_run ns env WGB_STATE_DIR="$KILL_DIR" WGB_ETC_DIR="$WORK/etc8" WGB_OUT_BASE="$WORK/out8" \
  "$WGB" down --iface=wgbi8
assert_eq 'down recovers from the killed bring-up' '0' "$RC"
assert_eq 'no rules were left behind' 'no' "$(ns_has_table && printf yes || printf no)"
assert_eq 'no interface was left behind' 'no' \
  "$(ns ip link show dev wgbi8 >/dev/null 2>&1 && printf yes || printf no)"
assert_eq 'forwarding is back to the value recorded before the crash' "$FWD_BEFORE_CRASH" \
  "$(ns_forwarding)"
assert_eq 'the state file is gone' 'no' \
  "$([[ -e "$KILL_DIR/wgbi8.env" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'teardown removes the working files it created'
# A plain teardown keeps the profiles but must not leave its own state directory or the rendered
# ruleset behind; a purging teardown removes the output base too, when it emptied it.
maybe_run ns env WGB_STATE_DIR="$WORK/run9" WGB_ETC_DIR="$WORK/etc9" WGB_OUT_BASE="$WORK/out9" \
  "$WGB" up --iface=wgbi9 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up succeeds' '0' "$RC"
assert_eq 'the state directory holds the session and its ruleset' '2' \
  "$(compgen -G "$WORK/run9/*" | wc -l | tr -d ' ')"
maybe_run ns env WGB_STATE_DIR="$WORK/run9" WGB_ETC_DIR="$WORK/etc9" WGB_OUT_BASE="$WORK/out9" \
  "$WGB" down --iface=wgbi9
assert_eq 'a plain teardown succeeds' '0' "$RC"
assert_eq 'it removes the state directory instead of leaving it empty' 'no' \
  "$([[ -e "$WORK/run9" ]] && printf yes || printf no)"
assert_eq 'and it keeps the profiles' 'yes' \
  "$([[ -n "$(compgen -G "$WORK/out9/*/client.conf")" ]] && printf yes || printf no)"
# ...and the promise that goes with it: `qr` must still be able to reprint one. Teardown removed the
# state, so this only works through the newest-profile-directory fallback.
maybe_run ns env WGB_STATE_DIR="$WORK/run9" WGB_ETC_DIR="$WORK/etc9" WGB_OUT_BASE="$WORK/out9" \
  "$WGB" qr client
assert_eq 'qr reprints a kept profile after a plain teardown' '0' "$RC"
assert_contains 'and says it fell back to the newest directory' "$OUT" 'no session state'

maybe_run ns env WGB_STATE_DIR="$WORK/run9" WGB_ETC_DIR="$WORK/etc9" WGB_OUT_BASE="$WORK/out9" \
  "$WGB" up --iface=wgbi9 --endpoint 192.0.2.10 --wan lo
assert_eq 'a second bring-up succeeds' '0' "$RC"
maybe_run ns env WGB_STATE_DIR="$WORK/run9" WGB_ETC_DIR="$WORK/etc9" WGB_OUT_BASE="$WORK/out9" \
  "$WGB" down --iface=wgbi9 --purge
assert_eq 'a purging teardown succeeds' '0' "$RC"
assert_eq 'the config is gone' 'no' \
  "$([[ -e "$WORK/etc9/wgbi9.conf" ]] && printf yes || printf no)"
assert_eq 'the session directory is gone' '0' "$(compgen -G "$WORK/out9/*" | wc -l | tr -d ' ')"
assert_eq 'and the base it emptied is gone too' 'no' \
  "$([[ -e "$WORK/out9" ]] && printf yes || printf no)"

# `rmdir` cannot take a non-empty directory, so a base that still holds something else survives.
mkdir -p "$WORK/shared/out/keepme"
maybe_run ns env WGB_STATE_DIR="$WORK/run11" WGB_ETC_DIR="$WORK/etc11" \
  WGB_OUT_BASE="$WORK/shared/out" "$WGB" up --iface=wgbi11 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up into a shared base succeeds' '0' "$RC"
maybe_run ns env WGB_STATE_DIR="$WORK/run11" WGB_ETC_DIR="$WORK/etc11" \
  WGB_OUT_BASE="$WORK/shared/out" "$WGB" down --iface=wgbi11 --purge
assert_eq 'its teardown succeeds' '0' "$RC"
assert_eq 'the session directory is gone' 'no' \
  "$([[ -n "$(compgen -G "$WORK/shared/out/2*")" ]] && printf yes || printf no)"
assert_eq 'an unrelated directory inside the base survives' 'yes' \
  "$([[ -d "$WORK/shared/out/keepme" ]] && printf yes || printf no)"
assert_eq 'so the base itself survives' 'yes' \
  "$([[ -d "$WORK/shared/out" ]] && printf yes || printf no)"

maybe_run ns env WGB_STATE_DIR="$WORK/run10" WGB_ETC_DIR="$WORK/etc10" \
  WGB_OUT_BASE="$WORK/default/out" "$WGB" up --iface=wgbi10 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up with the default-shaped out/ succeeds' '0' "$RC"
maybe_run ns env WGB_STATE_DIR="$WORK/run10" WGB_ETC_DIR="$WORK/etc10" \
  WGB_OUT_BASE="$WORK/default/out" "$WGB" down --iface=wgbi10 --purge
assert_eq 'its teardown succeeds' '0' "$RC"
assert_eq 'the default-shaped out/ is removed once purge emptied it' 'no' \
  "$([[ -e "$WORK/default/out" ]] && printf yes || printf no)"
assert_eq 'the directory above it is left alone' 'yes' \
  "$([[ -d "$WORK/default" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'a purge from another working directory still finds the profiles'
# OUT_BASE defaults to $PWD/out, so a session started from one directory and torn down from
# another must adopt the base the session recorded: otherwise --purge silently leaves the
# profiles (and their private keys) exactly where they were.
mkdir -p "$WORK/elsewhere" "$WORK/cwdtest2"
maybe_run ns env -C "$WORK/cwdtest2" WGB_STATE_DIR="$WORK/run15" WGB_ETC_DIR="$WORK/etc15" \
  "$WGB" up --iface=wgbi15 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up from the scratch cwd succeeds' '0' "$RC"
assert_eq 'its profiles landed under that cwd' 'yes' \
  "$([[ -n "$(compgen -G "$WORK/cwdtest2/out/*/client.conf")" ]] && printf yes || printf no)"
maybe_run ns env -C "$WORK/elsewhere" WGB_STATE_DIR="$WORK/run15" WGB_ETC_DIR="$WORK/etc15" \
  "$WGB" down --iface=wgbi15 --purge
assert_eq 'teardown from a different directory succeeds' '0' "$RC"
assert_eq 'and it removed the profiles it could not have guessed the location of' 'no' \
  "$([[ -e "$WORK/cwdtest2/out" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'an explicit --iface still finds the session config directory'
CUSTOM15="$WORK/etc16"
maybe_run ns env WGB_STATE_DIR="$WORK/run16" WGB_OUT_BASE="$WORK/out16" "$WGB" up --iface=wgbi16 \
  --config-dir="$CUSTOM15" --endpoint 192.0.2.10 --wan lo
assert_eq 'up with --config-dir succeeds' '0' "$RC"
# Naming the interface explicitly must not lose the recorded config directory: coupling the two
# makes this purge delete a default-path config that never existed while the real key material
# stays in $CUSTOM15.
maybe_run ns env WGB_STATE_DIR="$WORK/run16" WGB_OUT_BASE="$WORK/out16" \
  "$WGB" down --iface=wgbi16 --purge
assert_eq 'down --iface=... --purge succeeds' '0' "$RC"
assert_eq 'the config in the chosen directory is gone' 'no' \
  "$([[ -e "$CUSTOM15/wgbi16.conf" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'a config directory other users can write to is refused'
# The config inside it is loaded by root, so a directory anyone can write to is a
# privilege-escalation shape. The help text states the rule; this is the enforcement.
UNSAFE_DIR="$WORK/unsafe"
mkdir -p "$UNSAFE_DIR"
chmod 777 "$UNSAFE_DIR"
maybe_run ns env WGB_STATE_DIR="$WORK/run17" WGB_OUT_BASE="$WORK/out17" "$WGB" up --iface=wgbi17 \
  --config-dir="$UNSAFE_DIR" --endpoint 192.0.2.10 --wan lo
assert_eq 'up into a world-writable config directory refuses' '1' "$RC"
assert_contains 'the refusal explains the escalation shape' "$OUT" 'lets other users replace it'
assert_contains 'and names the fix' "$OUT" 'chmod 700'
assert_eq 'nothing was written into it' '0' \
  "$(find "$UNSAFE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
assert_eq 'no session state was recorded' 'no' \
  "$([[ -e "$WORK/run17/wgbi17.env" ]] && printf yes || printf no)"
chmod 700 "$UNSAFE_DIR"

# ---------------------------------------------------------------------------
group 'a plain teardown says when key material is left behind'
# A backup holds the same private keys as the config. `down` keeps it on purpose, so it has to
# say so - and purge can only remove backups its own session recorded.
maybe_run ns env WGB_STATE_DIR="$WORK/run18" WGB_ETC_DIR="$WORK/etc18" WGB_OUT_BASE="$WORK/out18" \
  "$WGB" up --iface=wgbi18 --endpoint 192.0.2.10 --wan lo
assert_eq 'first bring-up succeeds' '0' "$RC"
maybe_run ns env WGB_STATE_DIR="$WORK/run18" WGB_ETC_DIR="$WORK/etc18" WGB_OUT_BASE="$WORK/out18" \
  "$WGB" up --iface=wgbi18 --endpoint 192.0.2.10 --wan lo
assert_contains 'the repeat run backs the existing config up' "$OUT" 'backed up'
maybe_run ns env WGB_STATE_DIR="$WORK/run18" WGB_ETC_DIR="$WORK/etc18" WGB_OUT_BASE="$WORK/out18" \
  "$WGB" down --iface=wgbi18
assert_eq 'a plain teardown succeeds' '0' "$RC"
assert_contains 'it names the backups it leaves behind' "$OUT" 'backups were left in place'
assert_contains 'and says how to remove them' "$OUT" 'down --purge'
assert_eq 'the backup is still there, keys and all' '1' \
  "$(compgen -G "$WORK/etc18/wgbi18.conf.bak-*" | wc -l | tr -d ' ')"
assert_eq 'while the config itself is kept by a plain teardown' 'yes' \
  "$([[ -e "$WORK/etc18/wgbi18.conf" ]] && printf yes || printf no)"
# This session's state is gone, so a later purge cannot know about this backup by design.
rm -f "$WORK/etc18/wgbi18.conf.bak-"*

# ---------------------------------------------------------------------------
group 'the advertised endpoint: behind NAT, and moving'
# A host with no public address of its own advertises one that belongs to whatever NATs for it:
# the client can then only connect if that device forwards the port. Reporting success without
# saying so is how an on-site hour disappears.
maybe_run ns env WGB_STATE_DIR="$WORK/run19" WGB_ETC_DIR="$WORK/etc19" WGB_OUT_BASE="$WORK/out19" \
  "$WGB" up --iface=wgbi19 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up with an endpoint this host does not hold succeeds' '0' "$RC"
assert_contains 'up calls out the behind-NAT endpoint' "$OUT" 'not an address this host holds'
assert_contains 'and names the address a forward would target' "$OUT" 'forwarded to'
maybe_run ns env WGB_STATE_DIR="$WORK/run19" WGB_ETC_DIR="$WORK/etc19" WGB_OUT_BASE="$WORK/out19" \
  "$WGB" up --iface=wgbi19 --endpoint 198.51.100.7 --wan lo
assert_eq 'a repeat bring-up with a different endpoint succeeds' '0' "$RC"
# A dynamic public address silently strands a profile that was already scanned onto a device.
assert_contains 'up warns that the advertised address moved' "$OUT" \
  'the endpoint changed since the last session'
assert_contains 'and says the old profile has to be re-sent' "$OUT" 're-send it'
maybe_run ns env WGB_STATE_DIR="$WORK/run19" WGB_ETC_DIR="$WORK/etc19" WGB_OUT_BASE="$WORK/out19" \
  "$WGB" down --iface=wgbi19 --purge
assert_eq 'teardown of that session succeeds' '0' "$RC"
assert_eq 'no state is left behind' 'no' \
  "$([[ -e "$WORK/run19" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'a repeat bring-up does not overwrite the recorded forwarding value'
# The tool enables ip_forward itself. Re-reading it on a second run would record "1" as the prior
# value, and the next `down` would then leave forwarding enabled for good.
ns sysctl -qw net.ipv4.ip_forward=0
maybe_run ns env WGB_STATE_DIR="$WORK/run20" WGB_ETC_DIR="$WORK/etc20" WGB_OUT_BASE="$WORK/out20" \
  "$WGB" up --iface=wgbi20 --endpoint 192.0.2.10 --wan lo
assert_eq 'first bring-up succeeds' '0' "$RC"
assert_eq 'forwarding is enabled by the tool' '1' "$(ns_forwarding)"
maybe_run ns env WGB_STATE_DIR="$WORK/run20" WGB_ETC_DIR="$WORK/etc20" WGB_OUT_BASE="$WORK/out20" \
  "$WGB" up --iface=wgbi20 --endpoint 192.0.2.10 --wan lo
assert_eq 'a repeat bring-up succeeds' '0' "$RC"
assert_eq 'the state still records the original prior value' '0' \
  "$(grep -m1 '^PRIOR_IP_FORWARD=' "$WORK/run20/wgbi20.env" | cut -d= -f2-)"
maybe_run ns env WGB_STATE_DIR="$WORK/run20" WGB_ETC_DIR="$WORK/etc20" WGB_OUT_BASE="$WORK/out20" \
  "$WGB" down --iface=wgbi20 --purge
assert_eq 'teardown succeeds' '0' "$RC"
assert_eq 'and forwarding is back to the value from before the session' '0' "$(ns_forwarding)"

# ---------------------------------------------------------------------------
group 'the default endpoint is an address this host actually holds'
# No --endpoint at all: whatever the tool picks must exist on this machine, and the profile must
# carry exactly what the session recorded. On a NATed host that is the only reachable answer.
maybe_run ns env WGB_STATE_DIR="$WORK/run21" WGB_ETC_DIR="$WORK/etc21" WGB_OUT_BASE="$WORK/out21" \
  "$WGB" up --iface=wgbi21 --wan lo
assert_eq 'bring-up with no --endpoint succeeds' '0' "$RC"
CHOSEN="$(grep -m1 '^ENDPOINT=' "$WORK/run21/wgbi21.env" | cut -d= -f2-)"
assert_eq 'an endpoint was recorded' 'yes' "$([[ -n "$CHOSEN" ]] && printf yes || printf no)"
assert_eq 'and it is an address this namespace holds' 'yes' \
  "$(ns ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$CHOSEN" && printf yes || printf no)"
assert_contains 'the client profile dials the same address' \
  "$(cat "$WORK/out21"/*/client.conf)" "Endpoint = $CHOSEN:"
assert_contains 'up explains why that address was chosen' "$OUT" 'main local address'
maybe_run ns env WGB_STATE_DIR="$WORK/run21" WGB_ETC_DIR="$WORK/etc21" WGB_OUT_BASE="$WORK/out21" \
  "$WGB" doctor --wan lo
assert_contains 'doctor reports the same reasoning' "$OUT" 'main local address'
maybe_run ns env WGB_STATE_DIR="$WORK/run21" WGB_ETC_DIR="$WORK/etc21" WGB_OUT_BASE="$WORK/out21" \
  "$WGB" down --iface=wgbi21 --purge
assert_eq 'teardown succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'profiles stay findable after the state is gone and from another directory'
# The output base defaults to $PWD/out, so a session started in one directory and queried from
# another used to find nothing. The profile index fixes that, and it is the reason `qr` is usable
# from anywhere once a session has run.
mkdir -p "$WORK/cwdA" "$WORK/cwdB"
maybe_run ns env -C "$WORK/cwdA" WGB_STATE_DIR="$WORK/run22" WGB_ETC_DIR="$WORK/etc22" \
  "$WGB" up --iface=wgbi22 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up from cwdA succeeds' '0' "$RC"
assert_eq 'the profiles landed under cwdA' 'yes' \
  "$([[ -n "$(compgen -G "$WORK/cwdA/out/*/client.conf")" ]] && printf yes || printf no)"
maybe_run ns env -C "$WORK/cwdA" WGB_STATE_DIR="$WORK/run22" WGB_ETC_DIR="$WORK/etc22" \
  "$WGB" down --iface=wgbi22
assert_eq 'a plain teardown succeeds' '0' "$RC"
maybe_run ns env -C "$WORK/cwdB" WGB_STATE_DIR="$WORK/run22" WGB_ETC_DIR="$WORK/etc22" \
  "$WGB" qr client
assert_eq 'qr from another directory still prints the profile' '0' "$RC"
assert_contains 'and says which directory it used' "$OUT" "$WORK/cwdA/out"

# ---------------------------------------------------------------------------
group 'a peer whose profile is lost is called out at bring-up'
# The private key lives only in that profile file. If it is gone, the device can never be imported
# again, and saying so at `up` time is the whole difference from discovering it later.
maybe_run ns env -C "$WORK/cwdA" WGB_STATE_DIR="$WORK/run23" WGB_ETC_DIR="$WORK/etc23" \
  "$WGB" up --iface=wgbi23 --endpoint 192.0.2.10 --wan lo
assert_eq 'first bring-up succeeds' '0' "$RC"
rm -rf "$WORK/cwdA/out"
maybe_run ns env -C "$WORK/cwdA" WGB_STATE_DIR="$WORK/run23" WGB_ETC_DIR="$WORK/etc23" \
  "$WGB" up --iface=wgbi23 --endpoint 192.0.2.10 --wan lo
assert_eq 'the repeat bring-up succeeds' '0' "$RC"
assert_contains 'it names the peer whose profile is missing' "$OUT" 'profiles are not on this machine'
assert_contains 'and says the key is only in that file' "$OUT" 'ONLY in its profile file'
assert_contains 'and gives the remedy' "$OUT" 'remove-client <name>'
assert_not_contains 'it does not claim the device needs nothing' "$OUT" \
  'a device that already'
maybe_run ns env -C "$WORK/cwdA" WGB_STATE_DIR="$WORK/run23" WGB_ETC_DIR="$WORK/etc23" \
  "$WGB" down --iface=wgbi23 --purge
assert_eq 'teardown succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'add-client resolves the session context, subnet included'
# The same missing context made add-client allocate addresses in the DEFAULT subnet even when the
# session was started with --subnet: the profile and the peer disagreed with the tunnel.
maybe_run ns env WGB_STATE_DIR="$WORK/run24" WGB_ETC_DIR="$WORK/etc24" WGB_OUT_BASE="$WORK/out24" \
  "$WGB" up --iface=wgbi24 --subnet 10.99.0.0/24 --endpoint 192.0.2.10 --wan lo
assert_eq 'bring-up on a custom subnet succeeds' '0' "$RC"
maybe_run ns env WGB_STATE_DIR="$WORK/run24" WGB_ETC_DIR="$WORK/etc24" WGB_OUT_BASE="$WORK/out24" \
  "$WGB" add-client extra
assert_eq 'add-client on that session succeeds' '0' "$RC"
assert_contains 'the new address is inside the session subnet' "$OUT" '10.99.0.3/32'
assert_eq 'and the profile it wrote dials that session endpoint' 'yes' \
  "$(grep -q "^Endpoint = 192.0.2.10:51820$" "$WORK/out24"/*/extra.conf && printf yes || printf no)"
maybe_run ns env WGB_STATE_DIR="$WORK/run24" WGB_ETC_DIR="$WORK/etc24" WGB_OUT_BASE="$WORK/out24" \
  "$WGB" down --iface=wgbi24 --purge
assert_eq 'teardown succeeds' '0' "$RC"

# ---------------------------------------------------------------------------
group 'the ufw routed policy, quoted rather than assumed'
# The operator's "I allow all incoming" does not cover forwarded traffic, so doctor reads ufw's own
# output instead of paraphrasing it. test/helpers/fake-ufw supplies that output on hosts without ufw.
mkdir -p "$WORK/fakebin"
cp "$ROOT/test/helpers/fake-ufw" "$WORK/fakebin/ufw"
chmod +x "$WORK/fakebin/ufw"
mkdir -p "$WORK/ufwstate"
: >"$WORK/ufwstate/calls"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run25" WGB_ETC_DIR="$WORK/etc25" \
  "$WGB" doctor --endpoint 192.0.2.10 --wan lo
assert_contains 'doctor quotes the ufw default line' "$OUT" 'disabled (routed)'
assert_contains 'doctor says incoming rules do not govern forwarding' "$OUT" \
  'do NOT apply to forwarded traffic'
assert_contains 'doctor gives the ufw route command' "$OUT" 'ufw route allow from 10.13.37.0/24'

# ---------------------------------------------------------------------------
group 'up adds the ufw route rule, and down removes exactly that'
# The rule is applied by the tool and recorded in the session state, because a DROP policy in another
# chain cannot be overridden from inside this one. Nothing a user added themselves is ever removed.
mkdir -p "$WORK/ufwstate"
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
# The dropping table must look like ufw's own for the tool to treat it as ufw's to fix: ufw builds its
# `ufw-*` chains inside `ip filter`, and a DROP policy in another product's table is not ufw's to lift.
ns nft add table ip filter
ns nft "add chain ip filter ufw-user-forward"
ns nft "add chain ip filter ufwfilter { type filter hook forward priority filter; policy drop; }"
ns nft "add rule ip filter ufwfilter jump ufw-user-forward"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run26" WGB_ETC_DIR="$WORK/etc26" WGB_OUT_BASE="$WORK/out26" \
  "$WGB" up --iface=wgbi26 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds with a competing DROP chain' '0' "$RC"
assert_contains 'up says it allowed the tunnel subnet in ufw' "$OUT" \
  'allowed forwarded traffic from 10.13.37.0/24 in ufw'
assert_eq 'it asked ufw exactly once' '1' "$(grep -c '^route allow from 10.13.37.0/24$' "$WORK/ufwstate/calls")"
assert_eq 'the addition is recorded for teardown' 'ufw-route:10.13.37.0/24' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run26/wgbi26.env" | cut -d= -f2-)"
assert_eq 'ufw now lists the rule' 'yes' \
  "$(grep -q 'ALLOW FWD 10.13.37.0/24' "$WORK/ufwstate/rules" && printf yes || printf no)"

maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run26" WGB_ETC_DIR="$WORK/etc26" WGB_OUT_BASE="$WORK/out26" \
  "$WGB" down --iface=wgbi26 --purge
assert_eq 'teardown succeeds' '0' "$RC"
assert_contains 'down says it removed the rule this session added' "$OUT" \
  'removed the ufw route rule this session added'
assert_eq 'ufw no longer lists the rule' 'no' \
  "$(grep -q 'ALLOW FWD 10.13.37.0/24' "$WORK/ufwstate/rules" && printf yes || printf no)"

# --no-fix-firewall: report, change nothing.
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run27" WGB_ETC_DIR="$WORK/etc27" WGB_OUT_BASE="$WORK/out27" \
  "$WGB" up --iface=wgbi27 --endpoint 192.0.2.10 --wan lo --no-fix-firewall
assert_eq 'up --no-fix-firewall succeeds' '0' "$RC"
assert_contains 'it still reports the drop and the manual fix' "$OUT" 'Fix:'
assert_eq 'and it did not touch ufw' '0' "$(grep -c '^route allow' "$WORK/ufwstate/calls" || true)"
assert_eq 'and it records no fix to undo' '' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run27/wgbi27.env" | cut -d= -f2-)"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run27" WGB_ETC_DIR="$WORK/etc27" WGB_OUT_BASE="$WORK/out27" \
  "$WGB" down --iface=wgbi27 --purge
assert_eq 'teardown of that session succeeds' '0' "$RC"
assert_eq 'and it deleted nothing' '0' "$(grep -c '^delete' "$WORK/ufwstate/calls" || true)"

# A rule the user already had: do not duplicate it, and do not remove it on teardown.
printf 'ALLOW FWD 10.13.37.0/24\n' >"$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run28" WGB_ETC_DIR="$WORK/etc28" WGB_OUT_BASE="$WORK/out28" \
  "$WGB" up --iface=wgbi28 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds when the rule already exists' '0' "$RC"
assert_contains 'up leaves an existing rule alone' "$OUT" 'already allowed in ufw'
assert_eq 'no duplicate rule was added' '0' "$(grep -c '^route allow' "$WORK/ufwstate/calls" || true)"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run28" WGB_ETC_DIR="$WORK/etc28" WGB_OUT_BASE="$WORK/out28" \
  "$WGB" down --iface=wgbi28 --purge
assert_eq 'teardown succeeds' '0' "$RC"
assert_eq 'and the user rule is still there' 'yes' \
  "$(grep -q 'ALLOW FWD 10.13.37.0/24' "$WORK/ufwstate/rules" && printf yes || printf no)"

# An INCOMING allow is not a routed one. ufw renders them differently ("ALLOW" vs "ALLOW FWD"), and
# the operator who says "my ufw already allows all incoming" has exactly this line in their status.
# Treating it as already-allowed would report the client's dead internet as fixed.
printf 'Anywhere                   ALLOW       10.13.37.0/24\n' >"$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run35" WGB_ETC_DIR="$WORK/etc35" WGB_OUT_BASE="$WORK/out35" \
  "$WGB" up --iface=wgbi35 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds with only an incoming allow present' '0' "$RC"
assert_contains 'it adds the routed rule anyway' "$OUT" \
  'allowed forwarded traffic from 10.13.37.0/24 in ufw'
assert_eq 'exactly one routed rule was added' '1' "$(grep -c '^route allow' "$WORK/ufwstate/calls")"
assert_eq 'and the record was set' 'ufw-route:10.13.37.0/24' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run35/wgbi35.env" | cut -d= -f2-)"
rm -f "$WORK/ufwstate/rules"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run35" WGB_ETC_DIR="$WORK/etc35" WGB_OUT_BASE="$WORK/out35" \
  "$WGB" down --iface=wgbi35 --purge
assert_eq 'teardown succeeds' '0' "$RC"

# A repeat `up` rewrites the state file wholesale: what the first run recorded must survive it, or
# `down` would leave the ufw rule behind (and `--purge` the earlier config backups) while reporting a
# clean teardown.
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run34" WGB_ETC_DIR="$WORK/etc34" WGB_OUT_BASE="$WORK/out34" \
  "$WGB" up --iface=wgbi34 --endpoint 192.0.2.10 --wan lo
assert_eq 'first up succeeds' '0' "$RC"
assert_eq 'and adds the routed rule' '1' "$(grep -c '^route allow' "$WORK/ufwstate/calls")"
for _ in 1 2; do
  sleep 1
  maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
    WGB_STATE_DIR="$WORK/run34" WGB_ETC_DIR="$WORK/etc34" WGB_OUT_BASE="$WORK/out34" \
    "$WGB" up --iface=wgbi34 --endpoint 192.0.2.10 --wan lo
done
assert_eq 'the repeat up succeeds' '0' "$RC"
assert_contains 'it recognises its own rule' "$OUT" 'already in place from a session this tool ran'
assert_eq 'and did not add another' '1' "$(grep -c '^route allow' "$WORK/ufwstate/calls")"
assert_eq 'the firewall fix survives the repeat up' 'ufw-route:10.13.37.0/24' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run34/wgbi34.env" | cut -d= -f2-)"
assert_eq 'and every backup this session made is still listed' '2' \
  "$(grep -m1 '^BACKUPS=' "$WORK/run34/wgbi34.env" | cut -d= -f2- | wc -w)"

maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run34" WGB_ETC_DIR="$WORK/etc34" WGB_OUT_BASE="$WORK/out34" \
  "$WGB" down --iface=wgbi34 --purge
assert_eq 'teardown succeeds' '0' "$RC"
assert_eq 'it removed the rule with ufw route delete, once' '1' \
  "$(grep -c '^route delete allow from 10.13.37.0/24$' "$WORK/ufwstate/calls")"
assert_eq 'and ufw no longer lists it' 'no' \
  "$(grep -q 'ALLOW FWD' "$WORK/ufwstate/rules" && printf yes || printf no)"
shopt -s nullglob
bak34=("$WORK"/etc34/*.bak-*)
shopt -u nullglob
assert_eq 'and both backups were purged' '0' "${#bak34[@]}"
ns nft delete table ip filter

# ---------------------------------------------------------------------------
group 'an installed-but-inactive ufw is not mistaken for an active one'
# `ufw status` prints "Status: inactive", which contains the word "active". A substring test read that
# as active and added a route rule to a switched-off firewall - and told the operator the drop was
# fixed. The whole line must match, and when ufw is off the tool must not touch it at all.
mkdir -p "$WORK/ufwstate"
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
touch "$WORK/ufwstate/inactive"
ns nft add table ip filter
ns nft "add chain ip filter fwdroptest { type filter hook forward priority filter; policy drop; }"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run29" WGB_ETC_DIR="$WORK/etc29" WGB_OUT_BASE="$WORK/out29" \
  "$WGB" up --iface=wgbi29 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds' '0' "$RC"
assert_contains 'it reports that ufw is installed but not active' "$OUT" \
  'ufw is installed but not active'
assert_contains 'and still names the dropping table' "$OUT" 'ip filter'
assert_eq 'it did not add any ufw rule' '0' "$(grep -c '^route allow' "$WORK/ufwstate/calls" || true)"
assert_eq 'and recorded no fix to undo' '' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run29/wgbi29.env" | cut -d= -f2-)"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run29" WGB_ETC_DIR="$WORK/etc29" WGB_OUT_BASE="$WORK/out29" \
  "$WGB" down --iface=wgbi29 --purge
assert_eq 'teardown succeeds' '0' "$RC"
assert_eq 'and deleted nothing from ufw' '0' "$(grep -c '^delete' "$WORK/ufwstate/calls" || true)"
# doctor's own ufw block had the same substring bug ("Status: inactive" contains "active").
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run29" WGB_ETC_DIR="$WORK/etc29" \
  "$WGB" doctor --endpoint 192.0.2.10 --wan lo
assert_contains 'doctor calls an inactive ufw not active' "$OUT" 'ufw is installed but not active'
assert_eq 'and does not warn about its routed policy' '0' \
  "$(printf '%s' "$OUT" | grep -c 'incoming rules do NOT apply' || true)"
ns nft delete table ip filter
rm -f "$WORK/ufwstate/inactive"

# ---------------------------------------------------------------------------
group 'when ufw is not the owner, the advisory names who is'
# The chains inside the table give the owner away; naming it and printing the command that product
# documents is the difference between advice and a puzzle. The tool still changes nothing itself.
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
touch "$WORK/ufwstate/inactive"
ns nft add table ip filter
ns nft "add chain ip filter DOCKER-USER"
ns nft "add chain ip filter dockerfwd { type filter hook forward priority filter; policy drop; }"
ns nft "add rule ip filter dockerfwd jump DOCKER-USER"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run30" WGB_ETC_DIR="$WORK/etc30" WGB_OUT_BASE="$WORK/out30" \
  "$WGB" up --iface=wgbi30 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds' '0' "$RC"
assert_contains 'the advisory names docker' "$OUT" "holds docker's chains"
assert_contains 'and gives the command docker documents' "$OUT" \
  'iptables -I DOCKER-USER -s 10.13.37.0/24 -j ACCEPT'
assert_eq 'and it still changed nothing' '0' "$(grep -c '^route allow' "$WORK/ufwstate/calls" || true)"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run30" WGB_ETC_DIR="$WORK/etc30" WGB_OUT_BASE="$WORK/out30" \
  "$WGB" down --iface=wgbi30 --purge
assert_eq 'teardown succeeds' '0' "$RC"
ns nft delete table ip filter

# ---------------------------------------------------------------------------
group "an active ufw is not credited with fixing another product's DROP policy"
# ufw being active says nothing about a dropping chain that belongs to something else: a ufw route
# rule cannot lift it, so adding one would report a fix that did not happen. The tool must say whose
# chain it is and leave the firewall alone.
: >"$WORK/ufwstate/calls"
rm -f "$WORK/ufwstate/inactive" "$WORK/ufwstate/rules"
ns nft add table inet notufw
ns nft "add chain inet notufw notufw_forward { type filter hook forward priority filter; policy drop; }"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run32" WGB_ETC_DIR="$WORK/etc32" WGB_OUT_BASE="$WORK/out32" \
  "$WGB" up --iface=wgbi32 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds' '0' "$RC"
assert_contains "it says the drop is not ufw's to lift" "$OUT" "is not ufw's to lift"
assert_contains 'and names the table that owns it' "$OUT" 'inet notufw'
assert_eq 'it did not add a ufw rule that cannot help' '0' \
  "$(grep -c '^route allow' "$WORK/ufwstate/calls" || true)"
assert_eq 'and recorded no fix' '' \
  "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run32/wgbi32.env" | cut -d= -f2-)"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run32" WGB_ETC_DIR="$WORK/etc32" WGB_OUT_BASE="$WORK/out32" \
  "$WGB" down --iface=wgbi32 --purge
assert_eq 'teardown succeeds' '0' "$RC"
ns nft delete table inet notufw

# ---------------------------------------------------------------------------
group 'add-client with no session state: the config itself says which subnet and MTU'
# A plain `down` deletes the state file and a reboot clears /run, so the config on disk is the only
# record left. Allocating the new peer from the DEFAULT subnet would place it outside the tunnel its
# peers live in - a profile that cannot work.
mkdir -p "$WORK/etc36"
chmod 700 "$WORK/etc36"
sk36="$(wg genkey)"
pk36="$(printf '%s' "$sk36" | wg pubkey)"
printf '[Interface]\nAddress = 10.20.30.1/24\nListenPort = 51820\nPrivateKey = %s\nMTU = 1280\n\n[Peer]\n# client: old\nPublicKey = %s\nAllowedIPs = 10.20.30.2/32\n' \
  "$sk36" "$pk36" >"$WORK/etc36/wgbi36.conf"
chmod 600 "$WORK/etc36/wgbi36.conf"
maybe_run ns env WGB_STATE_DIR="$WORK/run36" WGB_ETC_DIR="$WORK/etc36" WGB_OUT_BASE="$WORK/out36" \
  "$WGB" add-client tablet --iface=wgbi36 --endpoint 192.0.2.10
assert_eq 'add-client succeeds with no session state' '0' "$RC"
shopt -s nullglob
out36=("$WORK"/out36/*/tablet.conf)
shopt -u nullglob
conf36="${out36[0]:-}"
assert_eq 'a profile was written' 'yes' "$([[ -f "$conf36" ]] && printf yes || printf no)"
assert_contains 'the new peer is in the config subnet, not the default one' \
  "$(cat "$conf36" 2>/dev/null)" 'Address = 10.20.30.3/32'
assert_contains 'and keeps the MTU the tunnel was built with' "$(cat "$conf36" 2>/dev/null)" 'MTU = 1280'
assert_contains 'and the server config got the same address' "$(cat "$WORK/etc36/wgbi36.conf")" \
  'AllowedIPs = 10.20.30.3/32'

# ---------------------------------------------------------------------------
group 'what the tool changed outside itself survives a reboot, and stays revertable'
# /run is tmpfs, so a reboot empties the session state - while the ufw rule and a key-bearing config
# backup are on disk. Recorded only in /run, a post-reboot `down` could neither revert them nor know
# they existed. The durable record is what keeps that promise.
: >"$WORK/index/undo-log"
mkdir -p "$WORK/ufwstate"
rm -f "$WORK/ufwstate/rules"
: >"$WORK/ufwstate/calls"
ns nft add table ip filter
ns nft "add chain ip filter ufw-user-forward"
ns nft "add chain ip filter ufwfilter2 { type filter hook forward priority filter; policy drop; }"
ns nft "add rule ip filter ufwfilter2 jump ufw-user-forward"
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run37" WGB_ETC_DIR="$WORK/etc37" WGB_OUT_BASE="$WORK/out37" \
  "$WGB" up --iface=wgbi37 --endpoint 192.0.2.10 --wan lo
assert_eq 'up succeeds' '0' "$RC"
assert_contains 'the firewall change is recorded outside /run' \
  "$(cat "$WORK/index/undo-log" 2>/dev/null)" 'ufw-route:10.13.37.0/24'

# The reboot: state gone, our kernel objects gone (a firewall re-creates its own tables at boot).
rm -rf "$WORK/run37"
ns nft delete table inet wgb
ns ip link del wgbi37 2>/dev/null
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run37" WGB_ETC_DIR="$WORK/etc37" WGB_OUT_BASE="$WORK/out37" \
  "$WGB" down --iface=wgbi37
assert_eq 'down after the reboot succeeds' '0' "$RC"
assert_contains 'and it still removes the rule it added before the reboot' "$OUT" \
  'removed the ufw route rule this session added'
assert_eq 'so ufw lists no routed rule again' 'no' \
  "$(grep -q 'ALLOW FWD' "$WORK/ufwstate/rules" && printf yes || printf no)"
assert_eq 'and the durable record is cleared' '0' \
  "$(grep -c 'ufw-route' "$WORK/index/undo-log" 2>/dev/null || true)"
assert_eq 'the WireGuard config itself was NOT wiped by the reboot' 'yes' \
  "$([[ -e "$WORK/etc37/wgbi37.conf" ]] && printf yes || printf no)"
assert_eq 'and a later up adopts nothing it does not own' 'no' \
  "$(grep -q 'adopts it' "$OUT" && printf yes || printf no)"

# A backup made before the reboot holds the same private keys: it must still be purgeable after it.
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run38" WGB_ETC_DIR="$WORK/etc38" WGB_OUT_BASE="$WORK/out38" \
  "$WGB" up --iface=wgbi38 --endpoint 192.0.2.10 --wan lo
sleep 1
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run38" WGB_ETC_DIR="$WORK/etc38" WGB_OUT_BASE="$WORK/out38" \
  "$WGB" up --iface=wgbi38 --endpoint 192.0.2.10 --wan lo
assert_eq 'the backup is recorded durably' '1' \
  "$(grep -c '^backup:' "$WORK/index/undo-log" 2>/dev/null || true)"
shopt -s nullglob
b38=("$WORK"/etc38/*.bak-*)
shopt -u nullglob
assert_eq 'and it exists on disk' '1' "${#b38[@]}"
rm -rf "$WORK/run38"
ns nft delete table inet wgb
ns ip link del wgbi38 2>/dev/null
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run38" WGB_ETC_DIR="$WORK/etc38" WGB_OUT_BASE="$WORK/out38" \
  "$WGB" down --iface=wgbi38 --purge
assert_eq 'purge after the reboot succeeds' '0' "$RC"
shopt -s nullglob
b38=("$WORK"/etc38/*.bak-*)
shopt -u nullglob
assert_eq 'and it removed the backup that outlived the session state' '0' "${#b38[@]}"
assert_eq 'and forgot the durable record of it' '0' \
  "$(grep -c '^backup:' "$WORK/index/undo-log" 2>/dev/null || true)"
assert_eq 'and removed the config' 'no' \
  "$([[ -e "$WORK/etc38/wgbi38.conf" ]] && printf yes || printf no)"

# doctor must name anything a previous session left behind, since /run cannot remember it.
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run39" WGB_ETC_DIR="$WORK/etc39" WGB_OUT_BASE="$WORK/out39" \
  "$WGB" up --iface=wgbi39 --endpoint 192.0.2.10 --wan lo
rm -rf "$WORK/run39"
ns nft delete table inet wgb
ns ip link del wgbi39 2>/dev/null
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run39" WGB_ETC_DIR="$WORK/etc39" \
  "$WGB" doctor --endpoint 192.0.2.10 --wan lo
assert_contains 'doctor reports what an earlier session left behind' "$OUT" \
  'an earlier session recorded changes this tool made'
assert_contains 'and names the entry' "$OUT" 'ufw-route:10.13.37.0/24'
maybe_run ns env PATH="$WORK/fakebin:$PATH" UFW_FAKE_DIR="$WORK/ufwstate" \
  WGB_STATE_DIR="$WORK/run39" WGB_ETC_DIR="$WORK/etc39" WGB_OUT_BASE="$WORK/out39" \
  "$WGB" down --iface=wgbi39 --purge
assert_eq 'final teardown succeeds' '0' "$RC"
assert_eq 'leaving nothing recorded' '0' "$(grep -c . "$WORK/index/undo-log" 2>/dev/null || true)"
ns nft delete table ip filter

# ---------------------------------------------------------------------------
# With no ufw on the host the same advisory must appear, and nothing may be attempted. This variant
# cannot be forced through PATH (`command -v` still reports a non-executable stand-in, and nft lives
# beside ufw in /usr/sbin), so it is asserted only where the host genuinely has no ufw.
if ! command -v ufw >/dev/null 2>&1; then
  group 'with no ufw installed at all, the tool only advises'
  ns nft add table inet noufwtest
  ns nft "add chain inet noufwtest noufw_forward { type filter hook forward priority filter; policy drop; }"
  maybe_run ns env WGB_STATE_DIR="$WORK/run31" WGB_ETC_DIR="$WORK/etc31" WGB_OUT_BASE="$WORK/out31" \
    "$WGB" up --iface=wgbi31 --endpoint 192.0.2.10 --wan lo
  assert_eq 'up succeeds with no ufw and a competing DROP chain' '0' "$RC"
  assert_contains 'it names the table that drops the packets' "$OUT" 'inet noufwtest'
  assert_contains 'and says what to allow' "$OUT" 'allow 10.13.37.0/24 there'
  assert_eq 'nothing was recorded as a firewall fix' '' \
    "$(grep -m1 '^FIREWALL_FIX=' "$WORK/run31/wgbi31.env" | cut -d= -f2-)"
  maybe_run ns env WGB_STATE_DIR="$WORK/run31" WGB_ETC_DIR="$WORK/etc31" WGB_OUT_BASE="$WORK/out31" \
    "$WGB" down --iface=wgbi31 --purge
  assert_eq 'teardown succeeds' '0' "$RC"
  ns nft delete table inet noufwtest
fi

# ---------------------------------------------------------------------------
group 'a purge reports the profile directories it did not write'
# Each session writes its own timestamped directory, and a purge removes THIS session's artifacts - so
# an older directory stays on disk, with a client private key inside it. Saying so is the difference
# between an honest purge and one that quietly leaves key material behind.
rm -rf "$WORK/out40" "$WORK/run40"
maybe_run ns env WGB_STATE_DIR="$WORK/run40" WGB_ETC_DIR="$WORK/etc40" WGB_OUT_BASE="$WORK/out40" \
  "$WGB" up --iface=wgbi40 --endpoint 192.0.2.10 --wan lo
assert_eq 'a first session writes a profile directory' '0' "$RC"
sleep 1
maybe_run ns env WGB_STATE_DIR="$WORK/run40" WGB_ETC_DIR="$WORK/etc40" WGB_OUT_BASE="$WORK/out40" \
  "$WGB" up --iface=wgbi40 --endpoint 192.0.2.10 --wan lo --clients 2
assert_eq 'a second session writes another one' '0' "$RC"
shopt -s nullglob
dirs40=("$WORK"/out40/*/)
shopt -u nullglob
assert_eq 'two profile directories exist' '2' "${#dirs40[@]}"
maybe_run ns env WGB_STATE_DIR="$WORK/run40" WGB_ETC_DIR="$WORK/etc40" WGB_OUT_BASE="$WORK/out40" \
  "$WGB" down --iface=wgbi40 --purge
assert_eq 'purge succeeds' '0' "$RC"
assert_contains 'and it names the directory it did not write' "$OUT" \
  'profile directories this session did not write'
assert_contains 'and says what that directory holds' "$OUT" 'private keys'
assert_eq 'the earlier directory is left in place, honestly' 'yes' \
  "$([[ -n "$(compgen -G "$WORK/out40/*/*.conf")" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------------
group 'the host was never touched'
if nft list table inet wgb >/dev/null 2>&1; then
  ko 'no wgb nft table on the host' 'the test leaked a table into the host namespace'
else
  ok 'no wgb nft table on the host'
fi
assert_eq 'no server config for the test interface on the host' 'no' \
  "$([[ -e "/etc/wireguard/$IFACE.conf" ]] && printf yes || printf no)"
assert_eq 'no state for the test interface on the host' 'no' \
  "$([[ -e "/run/wgb/$IFACE.env" ]] && printf yes || printf no)"
# The real-path group deliberately wrote into /etc/wireguard; prove it cleaned up after itself.
assert_eq 'no test leftovers in the real config directory' '0' \
  "$(compgen -G "/etc/wireguard/wgbint*" | wc -l | tr -d ' ')"

test_summary
