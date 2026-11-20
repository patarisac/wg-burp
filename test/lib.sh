#!/usr/bin/env bash
# Shared fixtures and assertions for the wgb test scripts.
# Sourced by run-tests.sh, integration-netns.sh and update-golden.sh.
#
# The keys below are throwaway test values generated for this suite. They are not used
# by, and must never be used for, a real tunnel.

# SC2034: these globals ARE the interface under test - they are read by the render_*
# functions in ../wgb, which shellcheck cannot see from here.
# shellcheck disable=SC2034

TEST_SERVER_PRIVKEY="pAsgWv6TQfm1hhjN7K3mdmGt1EfT6FtXVIIy+fIjYy4="
TEST_SERVER_PUBKEY="OCmxhidFKnDNIDuq3trOjlRkFZ4LN0zC/3Hp9SyZpEY="
TEST_CLIENT_PRIVKEY="VX8e7T2elH3V7o6sUmQWKe/Tl1DAWggg63P8uEJh8qA="
TEST_CLIENT_PUBKEY="f1UGot7KfquzErwHbfrR875sBsLXqE6Inz6O1ub/qIk="

# Deterministic render inputs: every render test starts from exactly this state.
setup_render_env() {
  IFACE="wgm0"
  SUBNET="10.13.37.0/24"
  DNS="1.1.1.1"
  LISTEN_PORT="51820"
  BURP_PORT="8083"
  MTU="1380"
  ALLOWED_IPS="0.0.0.0/0, ::/0"
  WAN_IFACE="wlan0"
  ENDPOINT="192.0.2.10"
  PROXY_MODE=1
  BLOCK_QUIC=1
  SERVER_PRIVKEY="$TEST_SERVER_PRIVKEY"
  SERVER_PUBKEY="$TEST_SERVER_PUBKEY"
  CLIENT_NAMES=("client")
  CLIENT_PRIVKEYS=("$TEST_CLIENT_PRIVKEY")
  CLIENT_PUBKEYS=("$TEST_CLIENT_PUBKEY")
  CLIENT_ADDRS=("10.13.37.2")
}

# --------------------------------------------------------------- assertions ---
PASS=0
FAILED=0

group() { printf '\n%s\n' "$1"; }

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }

ko() {
  FAILED=$((FAILED + 1))
  printf '  FAIL %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/       /'; fi
  # WGB_TEST_DEBUG=1 dumps the captured output of the last maybe_run alongside the failure:
  # without it a failing assertion that checks a command's output says nothing about why.
  if [[ -n "${WGB_TEST_DEBUG:-}" && -n "${OUT:-}" ]]; then
    printf '%s\n' "$OUT" | tail -25 | sed 's/^/       | /'
  fi
  return 0
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    ko "$1" "$(printf 'expected: %s\nactual:   %s' "$2" "$3")"
  fi
}

assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else ko "$1" "expected to contain: $3"; fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else ko "$1" "expected NOT to contain: $3"; fi
}

# maybe_run <command...> -> sets OUT and RC, never aborts the runner
maybe_run() {
  OUT="$("$@" 2>&1)"
  RC=$?
}

test_summary() {
  printf '\n%s\n' "------------------------------------------------------------"
  printf '%d passed, %d failed\n' "$PASS" "$FAILED"
  [[ "$FAILED" == 0 ]] || return 1
}
