#!/usr/bin/env bash
#
# The lint gate, in one place: CI runs this script and so should you, so the two cannot drift.
#
#   ./test/lint.sh
#
# The shellcheck version is pinned below and CI installs exactly that one. That is not fussiness: 0.9.0
# (what Ubuntu ships) and 0.11.0 (what this project uses) disagree about some checks, so a clean local
# run on a different version says nothing about CI - which is exactly how a green local run once went red
# on the first push. If your shellcheck differs, this says so and still runs.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SHELLCHECK_VERSION=0.11.0
FILES=(wgb install.sh test/*.sh test/helpers/fake-ufw completions/wgb.bash)

fail=0

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'lint: shellcheck is not installed (want %s)\n' "$SHELLCHECK_VERSION" >&2
  fail=1
else
  have="$(shellcheck --version | sed -n 's/^version: //p')"
  if [[ "$have" != "$SHELLCHECK_VERSION" ]]; then
    printf 'lint: shellcheck %s here, %s pinned - findings may differ from CI\n' "$have" "$SHELLCHECK_VERSION" >&2
  fi
  if shellcheck -x "${FILES[@]}"; then
    printf 'lint: shellcheck clean (%s)\n' "$have"
  else
    fail=1
  fi
fi

# The zsh completion is parsed by zsh itself: shellcheck cannot read zsh. (A comment that begins with
# the word "shellcheck" is read as a directive, which is why this one does not.)
if command -v zsh >/dev/null 2>&1; then
  if zsh -n completions/_wgb; then
    printf 'lint: zsh completion parses\n'
  else
    fail=1
  fi
else
  printf 'lint: zsh is not installed, skipping the zsh completion check\n' >&2
fi

exit "$fail"
