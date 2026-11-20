#!/usr/bin/env bash
# Live PF test on a disposable GitHub-hosted macOS runner, never an operator's Mac.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "$(uname -s)" != Darwin || $EUID != 0 || "${GITHUB_ACTIONS:-}" != true ||
      "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  printf 'This test needs root on a disposable GitHub-hosted macOS runner.\n' >&2
  exit 1
fi
[[ $# == 1 && -x "$1" ]] || { printf 'Pass the built wg-http probe.\n' >&2; exit 2; }
probe="$1"
# shellcheck source=../wgb
source ./wgb

umask 077
# First exercise the production path guard without creating its state directory.
default_state_dir="$(darwin_default_state_dir)"
trusted_root_path "$default_state_dir"
work="$(mktemp -d /private/var/db/wgb-ci.XXXXXX)"
WG_ETC_DIR="$work/config"
STATE_DIR="$work/state"
OUT_BASE="$work/profiles"
OUT_BASE_SET=1
INDEX_DIR="$work/index"
IFACE="wgbpf$$"
# This test-only child uses an existing hook on the disposable runner. It is not
# a recommendation to use Apple's namespace on an operator's Mac.
PF_PARENT=com.apple
SUBNET=198.18.77.0/24
BURP_PORT=48083
server="$(server_ip)"
client=198.18.77.2
target=198.51.100.42
marker=wgb-native-pf-redirect
mapping="/var/run/wireguard/$IFACE.name"
real=""
listener=""
run_wgb() ( main "$@"; )
snapshot() {
  pf -s rules >"$work/$1.filter" && pf -s nat >"$work/$1.nat" &&
    pf -s info >"$work/$1.info" && /usr/sbin/sysctl -n net.inet.ip.forwarding >"$work/$1.forward" &&
    awk '$1 == "Status:" { print $2 }' "$work/$1.info" >"$work/$1.status" && [[ -s "$work/$1.status" ]]
}
cleanup() {
  local rc=$? i
  if [[ -n "$listener" ]]; then kill "$listener" 2>/dev/null || true; wait "$listener" 2>/dev/null || true; fi
  if [[ -e "$(state_file)" ]]; then
    run_wgb down --iface "$IFACE" --purge || rc=1
    pf_child_empty || rc=1
    if [[ -e "$mapping" || -e "$(state_file)" || -e "$(pf_ref_file)" ]]; then
      printf 'macOS session was not cleared.\n' >&2
      rc=1
    fi
  fi
  if [[ -n "$real" ]]; then
    for i in 1 2 3 4 5; do
      if ! /sbin/ifconfig "$real" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if /sbin/ifconfig "$real" >/dev/null 2>&1; then printf 'Tunnel interface survived cleanup.\n' >&2; rc=1; fi
  fi
  if [[ -s "$work/before.status" ]]; then
    if ! snapshot after; then rc=1; else
      for i in filter nat status forward; do
        if ! cmp -s "$work/before.$i" "$work/after.$i"; then
          printf 'Unrelated host state changed: %s\n' "$i" >&2
          rc=1
        fi
      done
    fi
  fi
  if (( rc != 0 )) && [[ -f "$work/http.log" ]]; then cat "$work/http.log" >&2; fi
  rm -rf "$work"
  if (( rc == 0 )); then printf 'Verified test anchor removal, tunnel removal and unchanged host PF/forwarding state.\n'; fi
  exit "$rc"
}
# If a logical name is already present, never let cleanup target it.
if [[ -e "$mapping" || -L "$mapping" ]]; then rmdir "$work"; exit 1; fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot before
LISTEN_PORT="$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("",0)); print(s.getsockname()[1])')"
args=(up --iface "$IFACE" --endpoint 127.0.0.1 --subnet "$SUBNET" --listen-port "$LISTEN_PORT" --burp-port "$BURP_PORT")
run_wgb "${args[@]}" >"$work/up.log"
real="$(live_wg_iface "$IFACE")"
repeat_public="$(wg show "$real" public-key)"
run_wgb "${args[@]}" >>"$work/up.log"
[[ "$(live_wg_iface "$IFACE")" == "$real" && "$(wg show "$real" public-key)" == "$repeat_public" ]]
profile="$(find "$OUT_BASE" -name client.conf -type f -print)"
client_key="$(awk '$1=="PrivateKey" { print $3; exit }' "$profile")"
SERVER_PUBKEY="$(awk '$1=="PublicKey" { print $3; exit }' "$profile")"
[[ "$SERVER_PUBKEY" == "$repeat_public" && -n "$client_key" ]]

mkdir "$work/www"
printf '%s\n' "$marker" >"$work/www/index.html"
python3 -u -m http.server "$BURP_PORT" --bind "$server" --directory "$work/www" >"$work/http.log" 2>&1 &
listener=$!
for i in 1 2 3 4 5; do
  if grep -q 'Serving HTTP on' "$work/http.log"; then break; fi
  kill -0 "$listener" || { printf 'HTTP listener exited early.\n' >&2; exit 1; }
  sleep 1
done
grep -q 'Serving HTTP on' "$work/http.log"

key_hex() { python3 -c 'import base64, sys; print(base64.b64decode(sys.stdin.readline(), validate=False).hex())'; }
{
  printf 'private_key=%s\n' "$(key_hex <<<"$client_key")"
  printf 'public_key=%s\n' "$(key_hex <<<"$SERVER_PUBKEY")"
  printf 'endpoint=127.0.0.1:%s\nallowed_ip=%s/32\n\n' "$LISTEN_PORT" "$target"
} >"$work/client.uapi"
response="$("$probe" "$client" "http://$target/" <"$work/client.uapi")"
[[ "$response" == "$marker" ]]
grep -F "$client - -" "$work/http.log"
wg show "$real" latest-handshakes | awk '$2 > 0 { seen=1 } END { exit !seen }'
run_wgb wait --iface "$IFACE" --timeout 3
printf 'HTTP from an independent WireGuard peer reached the listener via native PF; Burp itself was not run.\n'
