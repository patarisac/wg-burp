#!/usr/bin/env bash
#
# End-to-end proof of the interception path, without a client.
#
# Two network namespaces joined by a veth pair: the server namespace runs `wgb up` and a
# real listener on the proxy port; the client namespace imports the *generated client
# profile* with wg-quick. Then a request is made from the client to an arbitrary address,
# and the test asserts it arrives at the listener. That is the whole product promise -
# traffic leaving the client lands on the proxy port - verified from both ends, exactly the
# way it will be verified on site.
#
#   sudo ./test/integration-tunnel.sh
#
# Needs root. Without it the script reports "skipped" and exits 0.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
WGB="$ROOT/wgb"

NS_S="wgb-e2e-server"
NS_C="wgb-e2e-client"
IFACE="wgbe0"
SRV_IP="10.99.0.1"
CLI_IP="10.99.0.2"
PROXY_PORT="8083"
TARGET="198.51.100.10" # TEST-NET-2: routable nowhere, yet reachable through a full tunnel
MARKER="wgb-end-to-end-ok"
WORK="$(mktemp -d)"
# Keep the profile index out of the real /var/lib/wgb, like the other two suites do.
export WGB_INDEX_DIR="$WORK/index"

# shellcheck source=lib.sh
source "$ROOT/test/lib.sh"

if [[ "$(id -u)" != 0 ]]; then
  printf 'skipped: this test needs root (namespaces, nft, wireguard-tools).\n'
  printf 'run it as: sudo %s\n' "$0"
  exit 0
fi
for tool in ip nft wg wg-quick python3 curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'skipped: %s is not installed.\n' "$tool"
    exit 0
  fi
done

# The kernel module, not just the tools: `wg-quick up` on the generated profile is the whole point of
# this suite, and wireguard-tools installs happily where the module cannot load (a container, some
# cloud kernels, a CI runner). Create one real interface in a throwaway namespace to find out, so the
# failure is a clean skip instead of a wall of errors that look like a bug in the tool.
have_wireguard() {
  local ns=wgb_wgprobe rc=0
  ip netns add "$ns" 2>/dev/null || return 1
  ip netns exec "$ns" ip link add dev wgprobe type wireguard 2>/dev/null || rc=1
  ip netns del "$ns" 2>/dev/null || true
  return $rc
}
have_wireguard || {
  printf 'skipped: the wireguard kernel module is not available on this host.\n'
  exit 0
}

LISTENER_PID=""
STUB_PID=""
cleanup() {
  if [[ -n "$LISTENER_PID" ]]; then kill "$LISTENER_PID" 2>/dev/null || true; fi
  if [[ -n "$STUB_PID" ]]; then kill "$STUB_PID" 2>/dev/null || true; fi
  ip netns exec "$NS_C" wg-quick down "$WORK/client/client.conf" >/dev/null 2>&1 || true
  ip netns del "$NS_C" 2>/dev/null || true
  ip netns del "$NS_S" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ns_s() { ip netns exec "$NS_S" "$@"; }
ns_c() { ip netns exec "$NS_C" "$@"; }

printf 'end-to-end test: %s -> %s -> listener on :%s\n' "$NS_C" "$NS_S" "$PROXY_PORT"

# ---------------------------------------------------------------------------
group 'build the two namespaces and the link between them'
if ! ip netns add "$NS_S" 2>/dev/null || ! ip netns add "$NS_C" 2>/dev/null; then
  printf 'skipped: could not create network namespaces\n'
  exit 0
fi
ns_s ip link set lo up
ns_c ip link set lo up
ip link add veth-s type veth peer name veth-c
ip link set veth-s netns "$NS_S"
ip link set veth-c netns "$NS_C"
ns_s ip addr add "$SRV_IP/24" dev veth-s
ns_s ip link set veth-s up
ns_c ip addr add "$CLI_IP/24" dev veth-c
ns_c ip link set veth-c up
assert_eq 'the client can reach the server address at the IP layer' '0' \
  "$(ns_c ping -c1 -W2 "$SRV_IP" >/dev/null 2>&1; printf '%s' "$?")"

# A stand-in for Burp: a real listener on the proxy port, serving one known file.
mkdir -p "$WORK/proxy"
printf '%s\n' "$MARKER" >"$WORK/proxy/index.html"
ns_s python3 -m http.server "$PROXY_PORT" --bind 0.0.0.0 --directory "$WORK/proxy" \
  >"$WORK/server.log" 2>&1 &
LISTENER_PID=$!
sleep 1

# ---------------------------------------------------------------------------
group 'server: real bring-up with the tool'
maybe_run ns_s env WGB_STATE_DIR="$WORK/srv-run" WGB_ETC_DIR="$WORK/srv-etc" \
  WGB_OUT_BASE="$WORK/srv-out" "$WGB" up --iface="$IFACE" --endpoint="$SRV_IP" --wan=veth-s
assert_eq 'up succeeds in the server namespace' '0' "$RC"
assert_contains 'up reports the tunnel' "$OUT" 'tunnel is up'
assert_eq 'the tunnel interface exists' 'yes' \
  "$(ns_s ip link show dev "$IFACE" >/dev/null 2>&1 && printf yes || printf no)"
assert_eq 'the ruleset is loaded' 'yes' \
  "$(ns_s nft list table inet wgb >/dev/null 2>&1 && printf yes || printf no)"
assert_contains 'the listener on the proxy port is reachable from the server itself' "$OUT" \
  "proxy listening on"

# ---------------------------------------------------------------------------
group 'client: import the generated profile exactly as a client would'
PROFILE="$(compgen -G "$WORK/srv-out/*/client.conf" | head -1)"
assert_eq 'up produced a client profile' 'yes' "$([[ -n "$PROFILE" ]] && printf yes || printf no)"
# Drop the DNS line: this is a namespace, not a client, and wg-quick would rewrite the
# host's /etc/resolv.conf through resolvconf.
mkdir -p "$WORK/client"
grep -v '^DNS =' "$PROFILE" >"$WORK/client/client.conf"
chmod 600 "$WORK/client/client.conf"
assert_contains 'the profile points the client at the server namespace' \
  "$(cat "$WORK/client/client.conf")" "Endpoint = $SRV_IP:51820"
assert_contains 'the profile routes everything into the tunnel' \
  "$(cat "$WORK/client/client.conf")" 'AllowedIPs = 0.0.0.0/0, ::/0'

maybe_run ns_c wg-quick up "$WORK/client/client.conf"
assert_eq 'the client brings the tunnel up from the generated profile' '0' "$RC"

# ---------------------------------------------------------------------------
group 'both ends agree: handshake, then traffic on the proxy port'
HANDSHAKE=0
for _ in $(seq 1 20); do
  if ns_s wg show "$IFACE" latest-handshakes 2>/dev/null | awk '$2 != 0 { found = 1 } END { exit !found }'; then
    HANDSHAKE=1
    break
  fi
  sleep 1
done
assert_eq 'the server sees a handshake from the client' '1' "$HANDSHAKE"

# curl's connection is aimed at an address that exists nowhere. If it succeeds, the packet
# went into the tunnel, was redirected by the wgb ruleset, and was answered by the listener.
ns_c timeout 15 curl -s "http://$TARGET/" >"$WORK/client-response.txt" 2>"$WORK/curl.err"
CURL_RC=$?
assert_eq 'the client request through the tunnel succeeds' '0' "$CURL_RC"
assert_contains 'the listener answered (marker came back through the tunnel)' \
  "$(cat "$WORK/client-response.txt" 2>/dev/null)" "$MARKER"
assert_contains 'the listener logged the request it received' \
  "$(cat "$WORK/server.log" 2>/dev/null)" 'GET / HTTP/1.1'
# The source address in the listener's log is the decisive detail: 10.13.37.2 is the
# tunnel address, so the request arrived through the tunnel and the redirect, not over the
# veth pair (which would show 10.99.0.2).
assert_contains 'the request arrived from the tunnel address' \
  "$(cat "$WORK/server.log" 2>/dev/null)" '10.13.37.2 - -'
assert_not_contains 'the request did not arrive over the veth pair' \
  "$(cat "$WORK/server.log" 2>/dev/null)" "$CLI_IP - -"
# The counters are the on-site diagnostic: `nft list table inet wgb` has to show WHICH rule matched.
# A rule carrying a counter is not enough - this proves the counter counts real traffic.
REDIRECT_PACKETS="$(ns_s nft list table inet wgb 2>/dev/null |
  awk '/counter .*redirect to :8083/ { for (i = 1; i <= NF; i++) if ($i == "packets") print $(i + 1) }')"
if [[ -n "$REDIRECT_PACKETS" ]] && ((REDIRECT_PACKETS > 0)); then
  ok 'the redirect rule counted the request (the on-site diagnostic is live)'
else
  ko 'the redirect rule counted the request (the on-site diagnostic is live)' \
    "packets=${REDIRECT_PACKETS:-none}"
fi

# ---------------------------------------------------------------------------
group 'IPv6 routed into an IPv4-only tunnel fails fast instead of black-holing'
# The profile sends ::/0 into the tunnel, and this tunnel carries IPv4 only. On a dual-stack network
# the client tries IPv6 first for most sites; if those packets vanish with no answer, the app waits
# and reports it as a TLS/connection failure - the on-site symptom ("many SSL errors", unchanged by
# --no-proxy). The profile therefore gives both ends a ULA link address (so the kernel can source the
# ICMPv6), and the ruleset rejects IPv6 in prerouting - before route lookup, which is where an IPv6
# packet with no route would otherwise die silently.
assert_contains 'the profile gives the client an IPv6 address to source from' \
  "$(cat "$WORK/client/client.conf")" 'Address = 10.13.37.2/32, fd13:37::2/64'
assert_eq 'the profile still routes IPv6 into the tunnel (no leak around the proxy)' 'yes' \
  "$(ns_c ip -6 route show table 51820 2>/dev/null | grep -q '^default dev client' && printf yes || printf no)"
V6_T0="$(date +%s%N)"
ns_c ping6 -c1 -W3 2001:4860:4860::8888 >/dev/null 2>&1
V6_RC=$?
V6_MS=$(( ($(date +%s%N) - V6_T0) / 1000000 ))
assert_eq 'IPv6 through the tunnel does not succeed' 'nonzero' \
  "$([[ "$V6_RC" -ne 0 ]] && printf nonzero || printf zero)"
if ((V6_MS < 1000)); then
  ok "the client is told at once, no black-hole wait (${V6_MS}ms)"
else
  ko "the client is told at once, no black-hole wait" "took ${V6_MS}ms - the packet vanished"
fi
V6_REJECT="$(ns_s nft list table inet wgb 2>/dev/null |
  awk '/nfproto ipv6/ && /reject/ { for (i = 1; i <= NF; i++) if ($i == "packets") print $(i + 1) }' |
  head -1)"
assert_eq 'the guard rule counted the IPv6 the client sent into the tunnel' 'nonzero' \
  "$([[ -n "$V6_REJECT" && "$V6_REJECT" -gt 0 ]] && printf nonzero || printf zero)"

# ---------------------------------------------------------------------------
group 'wait finds a handshake that predates it (the order a tester actually works in)'
# Scan the QR -> the client connects -> only then run wait. Demanding a handshake newer than
# wait's own start would time out in exactly that sequence, which is the normal one.
maybe_run ns_s env WGB_STATE_DIR="$WORK/srv-run" WGB_ETC_DIR="$WORK/srv-etc" \
  WGB_OUT_BASE="$WORK/srv-out" "$WGB" wait --timeout 10 --iface="$IFACE"
assert_eq 'wait succeeds on an already-connected client' '0' "$RC"
assert_contains 'wait reports the handshake' "$OUT" 'handshake received'
assert_contains 'wait names the peer from the config' "$OUT" 'client'

# ---------------------------------------------------------------------------
group 'DNS: a hardcoded resolver is redirected to the resolver the operator chose'
# Stub resolver on the server's WAN address, which is where the port-53 DNAT points.
cat >"$WORK/stub.py" <<'PY'
import socket, sys, threading

log = open(sys.argv[1], "a", buffering=1)


def note(kind, data, addr):
    log.write("%s %s %d bytes\n" % (kind, addr[0], len(data)))


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((sys.argv[2], 53))
    while True:
        data, addr = s.recvfrom(4096)
        note("UDP", data, addr)
        s.sendto(data[:2] + b"\x81\x80" + data[4:], addr)


def tcp():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((sys.argv[2], 53))
    s.listen(5)
    while True:
        conn, addr = s.accept()
        data = conn.recv(4096)
        note("TCP", data, addr)
        conn.sendall(data[:2] + b"\x81\x80" + data[4:])
        conn.close()


threading.Thread(target=udp, daemon=True).start()
tcp()
PY
: >"$WORK/stub.log"

# A DNS line in a client profile makes wg-quick call resolvconf, so this test must prove it
# leaves the host's resolver configuration alone.
RESOLV_BEFORE="$(md5sum /etc/resolv.conf 2>/dev/null | cut -d' ' -f1)"

ip netns exec "$NS_C" wg-quick down "$WORK/client/client.conf" >/dev/null 2>&1 || true
maybe_run ns_s env WGB_STATE_DIR="$WORK/srv-run" WGB_ETC_DIR="$WORK/srv-etc" \
  WGB_OUT_BASE="$WORK/srv-out" "$WGB" down --iface="$IFACE"
assert_eq 'the tunnel is down before the DNS test' '0' "$RC"

ns_s python3 "$WORK/stub.py" "$WORK/stub.log" "$SRV_IP" >/dev/null 2>&1 &
STUB_PID=$!
sleep 1

maybe_run ns_s env WGB_STATE_DIR="$WORK/srv-run" WGB_ETC_DIR="$WORK/srv-etc" \
  WGB_OUT_BASE="$WORK/srv-out" "$WGB" up --iface="$IFACE" --endpoint="$SRV_IP" --wan=veth-s \
  --dns="$SRV_IP"
assert_eq 'bring-up with a chosen resolver succeeds' '0' "$RC"
assert_contains 'the ruleset sends port 53 to the chosen resolver' \
  "$(cat "$WORK/srv-run/$IFACE.nft" 2>/dev/null)" "dnat to $SRV_IP"
assert_contains 'the same bring-up reused the client key' "$OUT" 'reusing the server key'

# The client's own DNS line is stripped: wg-quick hands a DNS line to resolvconf, which is
# what the client app would consume but wg-quick here cannot, and this test must not go
# anywhere near the host's resolver configuration. What matters for the DNAT is where a
# QUERY is sent, so the queries below aim at a resolver the operator does not control.
PROFILE_2="$(compgen -G "$WORK/srv-out/*/client.conf" | head -1)"
assert_eq 'the original profile is still available' 'yes' \
  "$([[ -n "$PROFILE_2" ]] && printf yes || printf no)"
assert_contains 'the profile does carry a resolver line' "$(cat "$PROFILE_2")" 'DNS = '
grep -v '^DNS =' "$PROFILE_2" >"$WORK/client/client.conf"
chmod 600 "$WORK/client/client.conf"
maybe_run ns_c wg-quick up "$WORK/client/client.conf"
assert_eq 'the client connects with the hardcoded resolver' '0' "$RC"

DNS_QUERY='\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
ns_c python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'$DNS_QUERY', ('198.51.100.53', 53))
time.sleep(0.5)
" || true
sleep 1
assert_contains 'the UDP query reached the resolver the operator chose' \
  "$(cat "$WORK/stub.log" 2>/dev/null)" 'UDP 10.13.37.2'

# Rule order, proved by behaviour: with the catch-all TCP redirect evaluated first, this query
# would land on the proxy port instead of the resolver.
PROXY_LINES_BEFORE="$(wc -l <"$WORK/server.log")"
ns_c python3 -c "
import socket
s = socket.create_connection(('198.51.100.53', 53), timeout=5)
s.sendall(b'$DNS_QUERY')
s.close()
" || true
sleep 1
assert_contains 'the TCP query reached the resolver, not the proxy port' \
  "$(cat "$WORK/stub.log" 2>/dev/null)" 'TCP 10.13.37.2'
assert_eq 'the proxy port received nothing from that query' \
  "$PROXY_LINES_BEFORE" "$(wc -l <"$WORK/server.log")"
assert_contains 'the resolver saw both queries from the tunnel address' \
  "$(cat "$WORK/stub.log" 2>/dev/null)" '10.13.37.2'
assert_not_contains 'no query arrived over the veth pair' \
  "$(cat "$WORK/stub.log" 2>/dev/null)" "$CLI_IP"

kill "$STUB_PID" 2>/dev/null || true
ip netns exec "$NS_C" wg-quick down "$WORK/client/client.conf" >/dev/null 2>&1 || true
assert_eq "the host's resolver configuration was not touched" \
  "$RESOLV_BEFORE" "$(md5sum /etc/resolv.conf 2>/dev/null | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
group 'teardown leaves nothing behind'
maybe_run ns_s env WGB_STATE_DIR="$WORK/srv-run" WGB_ETC_DIR="$WORK/srv-etc" \
  WGB_OUT_BASE="$WORK/srv-out" "$WGB" down --iface="$IFACE"
assert_eq 'down succeeds in the server namespace' '0' "$RC"
assert_eq 'the tunnel interface is gone' 'no' \
  "$(ns_s ip link show dev "$IFACE" >/dev/null 2>&1 && printf yes || printf no)"
assert_eq 'the nft table is gone' 'no' \
  "$(ns_s nft list table inet wgb >/dev/null 2>&1 && printf yes || printf no)"
if nft list table inet wgb >/dev/null 2>&1; then
  ko 'the host still has no wgb table' 'the test leaked a table onto the host'
else
  ok 'the host still has no wgb table'
fi
assert_eq 'the host has no config for the test interface' 'no' \
  "$([[ -e "/etc/wireguard/$IFACE.conf" ]] && printf yes || printf no)"

test_summary
