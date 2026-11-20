#!/usr/bin/env bash
# For a disposable macOS CI runner. Tests WireGuard only; never changes PF or forwarding.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "$(uname -s)" == Darwin && $EUID == 0 ]] || {
  printf 'Requires root on a disposable macOS runner.\n' >&2
  exit 1
}
# shellcheck source=../wgb
source ./wgb

sw_vers
wg --version
umask 077
work="$(mktemp -d)"
WG_ETC_DIR="$work"
IFACE="wgbci$$"
SUBNET=198.18.77.0/24
mapping="/var/run/wireguard/$IFACE.name"
[[ ! -e "$mapping" && ! -L "$mapping" ]] || {
  rmdir "$work"
  printf 'Logical WireGuard name already in use.\n' >&2
  exit 1
}
conf="$(server_conf_path)"
cleanup() {
  local rc=$?
  if [[ -e "$mapping" ]]; then
    if ! link_down "$IFACE" || [[ -e "$mapping" ]]; then
      printf 'WireGuard cleanup did not finish; config remains at %s\n' "$conf" >&2
      exit 1
    fi
  fi
  rm -f "$conf"
  rmdir "$work"
  exit "$rc"
}
trap cleanup EXIT

SERVER_PRIVKEY="$(wg genkey)"
expected="$(wg pubkey <<<"$SERVER_PRIVKEY")"
# WireGuard allocates a free port when ListenPort is zero. No peer or external traffic needed.
LISTEN_PORT=0
render_server_conf >"$conf"
link_up "$IFACE"
real="$(live_wg_iface "$IFACE")"
[[ "$(wg show "$real" public-key)" == "$expected" ]]
LISTEN_PORT="$(wg show "$real" listen-port)"
[[ "$LISTEN_PORT" =~ ^[1-9][0-9]*$ ]]
render_server_conf >"$conf"

link_up "$IFACE"
[[ "$(live_wg_iface "$IFACE")" == "$real" ]]
[[ "$(wg show "$real" public-key)" == "$expected" ]]
[[ "$(wg show "$real" listen-port)" == "$LISTEN_PORT" ]]

link_down "$IFACE"
for attempt in 1 2 3 4 5; do
  if ! /sbin/ifconfig "$real" >/dev/null 2>&1; then break; fi
  printf 'Waiting for WireGuard interface removal (attempt %s)\n' "$attempt"
  sleep 1
done
[[ ! -e "$mapping" ]]
! /sbin/ifconfig "$real" >/dev/null 2>&1 || { printf 'Interface survived teardown: %s\n' "$real" >&2; exit 1; }
printf 'Native WireGuard creation, repeat sync and teardown passed; PF and Burp traffic were not tested.\n'
