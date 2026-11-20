#!/usr/bin/env bash
#
# Tests for install.sh: what it installs, what it refuses, what it removes.
#
# Runs entirely inside a temporary --prefix, needs no root, and touches nothing under /usr/local or
# /usr/bin. That is deliberate: the point of the installer is that it can be run against a real
# prefix, so the test proves the same code path against a scratch one.
#
#   ./test/install-test.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

INSTALL="./install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wgb-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
GROUP=""

group() {
  GROUP="$1"
  printf '\n%s\n' "$GROUP"
}

ok() {
  PASSED=$((PASSED + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL %s\n' "$1"
}

assert_eq() { # <what> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}

assert_contains() { # <what> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1 (no '$3' in: $(printf '%s' "$2" | head -3 | tr '\n' '|'))"; fi
}

assert_file() { # <what> <path>
  if [[ -f "$2" ]]; then ok "$1"; else fail "$1 ($2 missing)"; fi
}

assert_symlink() { # <what> <path>
  if [[ -L "$2" ]]; then ok "$1"; else fail "$1 ($2 is not a symlink)"; fi
}

assert_gone() { # <what> <path>
  if [[ ! -e "$2" && ! -L "$2" ]]; then ok "$1"; else fail "$1 ($2 still exists)"; fi
}

run() { # <args...>  -> RC, OUT
  OUT="$("$@" 2>&1)"
  RC=$?
}

# ---------------------------------------------------------------------------
group 'usage and input validation'
run "$INSTALL" --help
assert_eq '--help exits 0' '0' "$RC"
assert_contains 'and documents --prefix' "$OUT" '--prefix DIR'
assert_contains 'and documents --uninstall' "$OUT" '--uninstall'
assert_contains 'and documents --destdir staging' "$OUT" '--destdir DIR'
assert_contains 'and says --no-completion covers both shells' "$OUT" 'bash and zsh completions'

run "$INSTALL" --nonsense
assert_eq 'an unknown option is a usage error (2)' '2' "$RC"
assert_contains 'and it is named in the message' "$OUT" '--nonsense'

run "$INSTALL" --prefix relative/path
assert_eq 'a relative --prefix is a usage error (2)' '2' "$RC"
assert_contains 'and the message says absolute' "$OUT" 'absolute'

# ---------------------------------------------------------------------------
group '--dry-run changes nothing'
P1="$WORK/p1"
run "$INSTALL" --dry-run --prefix "$P1"
assert_eq '--dry-run exits 0' '0' "$RC"
assert_contains 'it prints what it would install' "$OUT" "$P1/bin/wgb"
assert_contains 'and where the manifest would go' "$OUT" 'install-manifest'
assert_gone 'and creates nothing at all' "$P1"

# ---------------------------------------------------------------------------
group 'install into a scratch prefix'
run "$INSTALL" --prefix "$P1"
assert_eq 'install exits 0' '0' "$RC"
INSTALL_OUT="$OUT"
assert_contains 'it reports the version it installed' "$OUT" 'installed wgb 0.1.0'
assert_file 'the tool is installed' "$P1/bin/wgb"
assert_eq 'it is executable (0755)' '755' "$(stat -c %a "$P1/bin/wgb")"
if [[ -L "$P1/bin/wgb" ]]; then
  fail 'the tool is a real copy, not a symlink into the checkout'
else
  ok 'the tool is a real copy, not a symlink into the checkout'
fi
if cmp -s ./wgb "$P1/bin/wgb"; then
  ok 'the copy is byte-identical to the checkout'
else
  fail 'the copy is byte-identical to the checkout'
fi
assert_file 'the completion is installed' "$P1/share/bash-completion/completions/wgb"
assert_file 'the zsh completion is installed' "$P1/share/zsh/site-functions/_wgb"
assert_eq 'the zsh completion is 0644 (compinit refuses a group-writable one)' '644' \
  "$(stat -c %a "$P1/share/zsh/site-functions/_wgb")"
assert_file 'the README is installed' "$P1/share/doc/wgb/README.md"
assert_file 'the troubleshooting reference is installed' "$P1/share/doc/wgb/troubleshooting.md"
assert_file 'the LICENSE is installed' "$P1/share/doc/wgb/LICENSE"
assert_file 'the manifest is written' "$P1/share/wgb/install-manifest"

run bash -n "$P1/share/bash-completion/completions/wgb"
assert_eq 'the completion parses' '0' "$RC"

if command -v zsh >/dev/null 2>&1; then
  run zsh -n "$P1/share/zsh/site-functions/_wgb"
  assert_eq 'the zsh completion parses' '0' "$RC"
  # zsh loads a completion only from a directory on its fpath, and compinit refuses one that group or
  # others can write. Both are asserted against a real zsh, not assumed.
  run zsh -f -c "fpath=($P1/share/zsh/site-functions \$fpath); autoload -Uz compinit; compinit -C -d /dev/null; print \${_comps[wgb]:-none}"
  assert_eq 'and zsh registers it for wgb' '_wgb' "$OUT"
  assert_contains 'the install reports where the zsh completion went' "$INSTALL_OUT" 'zsh:'
fi

# It must run from anywhere: a tool that only works from its own directory is not installed.
( cd / && "$P1/bin/wgb" version ) >/dev/null 2>&1
assert_eq 'the installed tool runs from another directory' '0' "$?"
run "$P1/bin/wgb" version
assert_eq 'and reports the right version' 'wgb 0.1.0' "$OUT"

MANIFEST_LINES="$(grep -c '^path ' "$P1/share/wgb/install-manifest")"
assert_eq 'the six installed files are recorded in the manifest (the manifest itself is not)' '6' "$MANIFEST_LINES"
assert_eq 'and every recorded path exists' '0' \
  "$(grep '^path ' "$P1/share/wgb/install-manifest" | sed 's/^path //' | while read -r f; do [[ -e "$f" ]] || printf '%s\n' "$f"; done | wc -l | tr -d ' ')"
assert_eq 'nothing recorded escapes the prefix' '0' \
  "$(grep '^path ' "$P1/share/wgb/install-manifest" | sed 's/^path //' | grep -cv "^$P1/")"

# ---------------------------------------------------------------------------
group 'installing twice is safe'
run "$INSTALL" --prefix "$P1"
assert_eq 'a second install exits 0' '0' "$RC"
assert_contains 'and says it is replacing the existing one' "$OUT" 'upgrading'
assert_eq 'the manifest still lists six paths' '6' "$(grep -c '^path ' "$P1/share/wgb/install-manifest")"
run "$P1/bin/wgb" version
assert_eq 'and the tool still works' 'wgb 0.1.0' "$OUT"

# ---------------------------------------------------------------------------
group 'the completions cannot drift from the tool'
# The PARSER is the source of truth, not --help: a flag can be accepted without the help text
# mentioning it (--version was, until this was fixed). Both completion files must offer exactly what
# the parser takes.
PARSER_FLAGS="$(sed -n '/^parse_args() {/,/^}/p' wgb | grep -oE '\-\-[a-z][a-z-]+' | sort -u)"
BASH_FLAGS="$(grep -oE '\-\-[a-z][a-z-]+' completions/wgb.bash | sort -u)"
ZSH_FLAGS="$(grep -oE '\-\-[a-z][a-z-]+' completions/_wgb | sort -u)"
assert_eq 'the bash completion offers every flag the parser accepts' '' \
  "$(comm -23 <(printf '%s\n' "$PARSER_FLAGS") <(printf '%s\n' "$BASH_FLAGS"))"
assert_eq 'and invents none the parser rejects' '' \
  "$(comm -13 <(printf '%s\n' "$PARSER_FLAGS") <(printf '%s\n' "$BASH_FLAGS"))"
assert_eq 'the zsh completion offers every flag the parser accepts' '' \
  "$(comm -23 <(printf '%s\n' "$PARSER_FLAGS") <(printf '%s\n' "$ZSH_FLAGS"))"
assert_eq 'and invents none the parser rejects' '' \
  "$(comm -13 <(printf '%s\n' "$PARSER_FLAGS") <(printf '%s\n' "$ZSH_FLAGS"))"
assert_eq 'and the two completions offer the same set' '' \
  "$(comm -3 <(printf '%s\n' "$BASH_FLAGS") <(printf '%s\n' "$ZSH_FLAGS") | tr -d '[:space:]')"

# A completion that offers a flag the command rejects is worse than no completion, so every flag the
# completion gives a read-only verb is checked against the real command.
for verb in status list doctor ca; do
  run ./wgb "$verb" --iface=wgbprobe0 --config-dir "$WORK"
  assert_eq "the flags offered for '$verb' are all accepted" '' \
    "$(printf '%s' "$OUT" | grep -o 'unknown option' || true)"
done

# And called the way bash calls it, not merely parsed.
# shellcheck source=completions/wgb.bash
source completions/wgb.bash
probe_completion() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(( $# - 1 ))
  COMPREPLY=()
  _wgb
  printf '%s' "${COMPREPLY[*]}"
}
assert_contains 'an empty line offers the verbs' "$(probe_completion wgb "")" 'add-client'
assert_contains '--v offers --version' "$(probe_completion wgb --v)" '--version'
assert_contains 'up --d offers --dry-run' "$(probe_completion wgb up --d)" '--dry-run'
assert_contains 'up --d also offers --dns' "$(probe_completion wgb up --d)" '--dns'
assert_contains 'down - offers --purge' "$(probe_completion wgb down -)" '--purge'
assert_contains 'qr - offers --png' "$(probe_completion wgb qr -)" '--png'
assert_contains 'wait - offers --timeout' "$(probe_completion wgb wait -)" '--timeout'
assert_eq '--clients completes the counts' '1 2 3 4 5' "$(probe_completion wgb up --clients "")"

# ---------------------------------------------------------------------------
group 'the zsh completion is a working compdef file'
if command -v zsh >/dev/null 2>&1; then
  run zsh -n completions/_wgb
  assert_eq 'it parses under zsh' '0' "$RC"
  # zsh only loads a completion from a directory on its fpath, and compinit refuses one that group or
  # others can write - which is why it ships 0644 and install.sh says where it went. Both facts are
  # measured against a real zsh: a fresh dump file, or a stale ~/.zcompdump hides the answer.
  ZS="$WORK/zshsite"
  mkdir -p "$ZS"
  chmod 755 "$ZS"
  install -m 0644 completions/_wgb "$ZS/_wgb"
  # -C skips compinit's directory security check, which a checkout under a group-writable path (a
  # normal umask on a shared repo) can never satisfy. The mode requirement itself was measured at the
  # real location instead: /usr/local/share/zsh/site-functions/_wgb 0644 root:root registers the
  # completion, and the same file at 0664 is refused - which is why install.sh uses 0644.
  run zsh -f -c "fpath=($ZS \$fpath); autoload -Uz compinit; compinit -C -d /dev/null; print \${_comps[wgb]:-none}"
  assert_eq 'zsh registers it as the completion for wgb' '_wgb' "$OUT"
else
  ok 'zsh is not installed: the zsh completion checks are skipped'
fi

# ---------------------------------------------------------------------------
group 'a foreign file at the install path is not clobbered'
P2="$WORK/p2"
mkdir -p "$P2/bin"
printf '#!/bin/sh\necho not mine\n' >"$P2/bin/wgb"
run "$INSTALL" --prefix "$P2"
assert_eq 'it refuses (1)' '1' "$RC"
assert_contains 'and says why' "$OUT" 'not a wgb install'
assert_eq 'the foreign file is untouched' 'not mine' "$(sh "$P2/bin/wgb")"
run "$INSTALL" --prefix "$P2" --force
assert_eq '--force installs anyway' '0' "$RC"
run "$P2/bin/wgb" version
assert_eq 'and the path is now wgb' 'wgb 0.1.0' "$OUT"

# ---------------------------------------------------------------------------
group '--no-completion --no-doc installs only the tool'
P3="$WORK/p3"
run "$INSTALL" --prefix "$P3" --no-completion --no-doc
assert_eq 'it exits 0' '0' "$RC"
assert_file 'the tool is there' "$P3/bin/wgb"
assert_gone 'no completion' "$P3/share/bash-completion/completions/wgb"
assert_gone 'no zsh completion either' "$P3/share/zsh/site-functions/_wgb"
assert_gone 'no docs' "$P3/share/doc/wgb/README.md"
assert_gone 'and no troubleshooting reference' "$P3/share/doc/wgb/troubleshooting.md"

# ---------------------------------------------------------------------------
group '--destdir stages for packaging'
P4="$WORK/p4"
run "$INSTALL" --prefix /usr/local --destdir "$P4"
assert_eq 'it exits 0' '0' "$RC"
assert_file 'the tool lands under the staging root, at the absolute prefix' "$P4/usr/local/bin/wgb"
assert_file 'with its docs' "$P4/usr/local/share/doc/wgb/README.md"
assert_contains 'and it runs from the staged path' "$( "$P4/usr/local/bin/wgb" version 2>&1)" 'wgb 0.1.0'

# ---------------------------------------------------------------------------
group '--link is for development and says so'
P5="$WORK/p5"
run "$INSTALL" --prefix "$P5" --link
assert_eq 'it exits 0' '0' "$RC"
assert_symlink 'the path is a symlink' "$P5/bin/wgb"
assert_contains 'it warns that root executes whatever that file becomes' "$OUT" 'decides what'
assert_contains 'and that a copy is what real engagements want' "$OUT" 'install a copy'

# ---------------------------------------------------------------------------
group 'a prefix that needs root asks for root'
if (( EUID == 0 )); then
  ok 'running as root: the needs-root path cannot be exercised'
elif [[ -w /usr/local ]]; then
  ok 'this host lets the user write /usr/local: the needs-root path cannot be exercised'
else
  run "$INSTALL" --prefix /usr/local
  assert_eq 'installing to /usr/local without root fails (1)' '1' "$RC"
  assert_contains 'and says to re-run with sudo' "$OUT" 'needs root'
fi

# ---------------------------------------------------------------------------
group 'the install path must be a directory sudo can see'
# sudo finds commands in secure_path, not in the shell's PATH. A bin directory sudo cannot see means
# `sudo wgb up` is "command not found" even though the tool is installed - measured on a real host
# whose sudoers trims secure_path to "/usr/sbin:/usr/bin:/sbin:/bin".
mkdir -p "$WORK/fa" "$WORK/fc/sudoers.d" "$WORK/fb"
printf 'Defaults secure_path="/usr/sbin:/usr/bin:/sbin:/bin"\n' >"$WORK/fa/sudoers"
printf 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"\n' >"$WORK/fc/sudoers"
printf 'Defaults secure_path="/usr/sbin:/usr/bin:/sbin:/bin"\n' >"$WORK/fc/sudoers.d/99-trimmed"
printf '# a comment mentioning secure_path="/nowhere/bin"\nDefaults secure_path="/usr/local/bin:/usr/bin"\n' >"$WORK/fb/sudoers"

# shellcheck source=install.sh
source ./install.sh

assert_eq 'secure_path is read from sudoers' '/usr/sbin:/usr/bin:/sbin:/bin' \
  "$(WGB_INSTALL_SUDOERS="$WORK/fa/sudoers" detect_sudo_path)"
assert_eq 'the last definition wins, as sudo parses it (sudoers.d after sudoers)' \
  '/usr/sbin:/usr/bin:/sbin:/bin' "$(WGB_INSTALL_SUDOERS="$WORK/fc/sudoers" detect_sudo_path)"
assert_eq 'a commented-out line is not mistaken for the setting' '/usr/local/bin:/usr/bin' \
  "$(WGB_INSTALL_SUDOERS="$WORK/fb/sudoers" detect_sudo_path)"
assert_eq 'an unreadable sudoers is reported rather than guessed' '1' \
  "$(WGB_INSTALL_SUDOERS="$WORK/does-not-exist" detect_sudo_path >/dev/null 2>&1; echo $?)"
assert_eq 'path_in_list finds an exact entry' '0' \
  "$(path_in_list /usr/bin '/usr/sbin:/usr/bin:/sbin:/bin'; echo $?)"
assert_eq 'and is not fooled by a partial match' '1' \
  "$(path_in_list /usr/bin '/usr/sbin:/usr/local/bin'; echo $?)"

# An explicit --prefix is honoured even when sudo cannot see it, with a warning.
P7="$WORK/p7"
run env WGB_INSTALL_SUDOERS="$WORK/fa/sudoers" "$INSTALL" --prefix "$P7"
assert_eq 'an explicit prefix outside sudo PATH still installs' '0' "$RC"
assert_contains 'but it warns that sudo will not resolve it' "$OUT" "is not in sudo's PATH"
assert_file 'and the tool is there' "$P7/bin/wgb"

if (( EUID == 0 )); then
  ok 'running as root: the auto-switch is not exercised (it would install into the real /usr/bin)'
else
  # No prefix given and the default is invisible to sudo: the installer must move to one that is
  # visible instead of leaving a tool that sudo cannot run.
  run env WGB_INSTALL_SUDOERS="$WORK/fa/sudoers" "$INSTALL"
  assert_eq 'the default prefix is abandoned when sudo cannot see it (needs root for /usr/bin)' '1' "$RC"
  assert_contains 'and the installer says it is installing elsewhere' "$OUT" 'installing to /usr/bin instead'
  assert_contains 'and asks for root for that location' "$OUT" 'needs root'
  run env WGB_INSTALL_SUDOERS="$WORK/fb/sudoers" "$INSTALL"
  assert_eq 'with sudo able to see /usr/local/bin the default prefix is kept' '1' "$RC"
  assert_contains 'and it asks for root for /usr/local' "$OUT" '/usr/local'
  if [[ "$OUT" == *'installing to /usr/bin instead'* ]]; then
    fail 'no switch happens when sudo can see the default prefix'
  else
    ok 'no switch happens when sudo can see the default prefix'
  fi
fi

# ---------------------------------------------------------------------------
group 'a non-root uninstall never wanders into a system prefix'
# The fallback search exists so `sudo install.sh --uninstall` finds an install that auto-switched to
# /usr/bin. Without root (and without --destdir) it must stay in the caller's own prefix: otherwise
# an unrelated uninstall could reach a system-wide install the caller never made.
if (( EUID == 0 )); then
  ok 'running as root: the scoping guard is not exercised'
else
  P8="$WORK/p8"
  run "$INSTALL" --prefix "$P8"
  assert_eq 'installed into a private prefix' '0' "$RC"
  run "$INSTALL" --uninstall
  assert_eq 'a bare uninstall finds nothing outside that prefix (1)' '1' "$RC"
  assert_contains 'and says so plainly' "$OUT" 'nothing installed here to remove'
  if [[ "$OUT" == *'using the one under /usr'* ]]; then
    fail 'the search must not reach a system prefix without root'
  else
    ok 'the search must not reach a system prefix without root'
  fi
  assert_file 'and the private install is untouched' "$P8/bin/wgb"
fi

# ---------------------------------------------------------------------------
group 'uninstall finds a manifest that is not under the default prefix'
# The installer moves to /usr/bin when sudo cannot see /usr/local/bin, so an uninstall with no
# --prefix must still find what was installed. Staged, so the real /usr/bin is never touched.
S2="$WORK/stage2"
mkdir -p "$S2"
run "$INSTALL" --prefix /usr --destdir "$S2"
assert_eq 'a staged /usr install works' '0' "$RC"
assert_file 'the manifest lands under the staged /usr' "$S2/usr/share/wgb/install-manifest"
run "$INSTALL" --destdir "$S2" --uninstall
assert_eq 'uninstall with no --prefix exits 0' '0' "$RC"
assert_contains 'and says which manifest it used' "$OUT" 'using the one under'
assert_gone 'the staged tool is gone' "$S2/usr/bin/wgb"
assert_gone 'and so is its manifest' "$S2/usr/share/wgb/install-manifest"
# The prefix that was found must drive the pruning, not the default one: a first version kept the
# other three directories pointing at /usr/local and left empty directories behind.
assert_gone 'and the staged directories are pruned' "$S2/usr/share/doc/wgb"
assert_gone 'including the completion directory' "$S2/usr/share/bash-completion/completions"
assert_eq 'still no bogus skips' '0' "$(printf '%s' "$OUT" | grep -c 'outside the recorded prefix')"

# ---------------------------------------------------------------------------
group 'uninstall removes exactly what the manifest recorded'
FOREIGN="$P1/bin/something-else"
printf '#!/bin/sh\ntrue\n' >"$FOREIGN"
chmod 755 "$FOREIGN"
run "$INSTALL" --prefix "$P1" --uninstall
assert_eq 'uninstall exits 0' '0' "$RC"
assert_eq 'and it does not treat manifest metadata as paths' '0' \
  "$(printf '%s' "$OUT" | grep -c 'outside the recorded prefix')"
assert_gone 'the tool is gone' "$P1/bin/wgb"
assert_gone 'the completion is gone' "$P1/share/bash-completion/completions/wgb"
assert_gone 'the zsh completion is gone' "$P1/share/zsh/site-functions/_wgb"
assert_gone 'the docs are gone' "$P1/share/doc/wgb/README.md"
assert_gone 'and the troubleshooting reference too' "$P1/share/doc/wgb/troubleshooting.md"
assert_gone 'the manifest is gone' "$P1/share/wgb/install-manifest"
assert_file 'the foreign file in the same directory survives' "$FOREIGN"
assert_gone 'the empty directories this installer made were pruned' "$P1/share/doc/wgb"

run "$INSTALL" --prefix "$P1" --uninstall
assert_eq 'a second uninstall has nothing to do (1)' '1' "$RC"
assert_contains 'and says so plainly' "$OUT" 'nothing installed here to remove'

# ---------------------------------------------------------------------------
group 'a doctored manifest cannot delete outside its prefix'
P6="$WORK/p6"
run "$INSTALL" --prefix "$P6"
assert_eq 'installed for the manifest test' '0' "$RC"
VICTIM="$WORK/victim.txt"
printf 'important\n' >"$VICTIM"
printf 'path %s\n' "$VICTIM" >>"$P6/share/wgb/install-manifest"
run "$INSTALL" --prefix "$P6" --uninstall
assert_eq 'uninstall still exits 0' '0' "$RC"
assert_contains 'it refuses the path and says why' "$OUT" 'outside the recorded prefix'
assert_file 'and the file outside the prefix survives' "$VICTIM"

# ---------------------------------------------------------------------------
group 'lint (when shellcheck is available)'
if command -v shellcheck >/dev/null 2>&1; then
  run shellcheck -x install.sh completions/wgb.bash
  assert_eq 'install.sh and the completion are shellcheck clean' '0' "$RC"
else
  ok 'shellcheck not installed: skipped'
fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 )) || exit 1
exit 0
