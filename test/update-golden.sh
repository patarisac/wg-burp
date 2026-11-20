#!/usr/bin/env bash
#
# Regenerate the golden fixtures in test/golden/ from the current render layer.
#
# Run this ONLY when a change to the generated output is intentional, then read
# `git diff test/golden/` before committing. Regenerating to silence a red test
# throws away the only regression signal the render layer has.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=../wgb
source ./wgb
# shellcheck source=lib.sh
source ./test/lib.sh

setup_render_env

render_server_conf >test/golden/server.conf
render_client_conf 10.13.37.2 "$TEST_CLIENT_PRIVKEY" >test/golden/client.conf
render_nft >test/golden/rules.nft

printf 'regenerated:\n'
ls -1 test/golden/
printf '\nnow review: git diff test/golden/\n'
