#!/usr/bin/env bash
# Native parse-only gate for the macOS PF candidate. Never load rules or enable PF here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'macOS PF check requires Darwin; no native check was run.\n' >&2
  exit 1
fi

sw_vers
printf 'Architecture: %s\nBash: %s\n' "$(uname -m)" "$BASH_VERSION"
# shellcheck source=../wgb
source ./wgb

# The dynamic NAT target must be a real interface. The match-only utun name need not
# be created just to parse a rule.
wan="$(/sbin/route -n get default | awk '$1 == "interface:" { print $2 }')"
[[ -n "$wan" ]] || { printf 'No default-route interface on the runner.\n' >&2; exit 1; }
tun=utun42
[[ "$tun" != "$wan" ]] || tun=utun43
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check_rules() {
  local mode="$1" file="$work/$1.conf"
  shift
  "$@" >"$file"
  if ! sudo -n /sbin/pfctl -n -a wgb-ci -f "$file"; then
    printf 'Native PF parse failed (%s):\n' "$mode" >&2
    cat "$file" >&2
    return 1
  fi
  printf 'Native PF parse passed (%s)\n' "$mode"
}

check_rules proxy render_pf "$tun" "$wan"
PROXY_MODE=0 BLOCK_QUIC=0 check_rules no-proxy render_pf "$tun" "$wan"
DNS="$(server_ip)" check_rules local-dns render_pf "$tun" "$wan"
printf 'Parse-only: no PF rules loaded, no tunnel or Burp traffic tested.\n'
