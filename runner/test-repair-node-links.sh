#!/usr/bin/env bash
# Offline test for repair-node-links.sh. Builds a fake RUNNER_HOME in a temp
# dir (no runner, no network) and checks every case the script must handle.
# Run: bash runner/test-repair-node-links.sh
# The checks are single-quoted on purpose: check() evals them after the
# variables they read are set.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

here="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$here/repair-node-links.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

mknode() { # $1 = node dir
  mkdir -p "$1/bin" "$1/lib/node_modules/npm/bin" "$1/lib/node_modules/corepack/dist"
  printf '#!/usr/bin/env node\nrequire("../lib/cli.js")(process)\n' >"$1/lib/node_modules/npm/bin/npm-cli.js"
  printf '#!/usr/bin/env node\nconst cli = require("../lib/cli.js")\n' >"$1/lib/node_modules/npm/bin/npx-cli.js"
  printf '#!/usr/bin/env node\nrequire("./lib/corepack.cjs")\n' >"$1/lib/node_modules/corepack/dist/corepack.js"
  printf 'ELF' >"$1/bin/node"
}

home="$tmp/runner"
# Broken update: dereferenced copies in node20 and node24.
for v in node20 node24; do
  d="$home/externals.2.338.0/$v"; mknode "$d"
  cp "$d/lib/node_modules/npm/bin/npm-cli.js" "$d/bin/npm"
  cp "$d/lib/node_modules/npm/bin/npx-cli.js" "$d/bin/npx"
  cp "$d/lib/node_modules/corepack/dist/corepack.js" "$d/bin/corepack"
done
# Alpine build ships node only.
mkdir -p "$home/externals.2.338.0/node24_alpine/bin"; printf 'ELF' >"$home/externals.2.338.0/node24_alpine/bin/node"
# Healthy older install: already links.
d="$home/externals.2.337.0/node24"; mknode "$d"
ln -s ../lib/node_modules/npm/bin/npm-cli.js "$d/bin/npm"
# A bin/npx that differs from its target must be left alone.
printf 'custom\n' >"$d/bin/npx"
ln -s "$home/externals.2.338.0" "$home/externals"

out="$("$script" "$home")"
for v in node20 node24; do
  b="$home/externals.2.338.0/$v/bin"
  check "$v npm is a link"      '[ "$(readlink "$b/npm")" = ../lib/node_modules/npm/bin/npm-cli.js ]'
  check "$v npx is a link"      '[ "$(readlink "$b/npx")" = ../lib/node_modules/npm/bin/npx-cli.js ]'
  check "$v corepack is a link" '[ "$(readlink "$b/corepack")" = ../lib/node_modules/corepack/dist/corepack.js ]'
  check "$v npm resolves"       '[ -f "$b/npm" ]'
  check "$v node untouched"     '[ -f "$b/node" ] && [ ! -L "$b/node" ]'
done
b="$home/externals.2.337.0/node24/bin"
check "existing link untouched"     '[ "$(readlink "$b/npm")" = ../lib/node_modules/npm/bin/npm-cli.js ]'
check "differing file left alone"   '[ ! -L "$b/npx" ] && [ "$(cat "$b/npx")" = custom ]'
check "missing entry not created"   '[ ! -e "$b/corepack" ]'
check "alpine dir untouched"        '[ "$(ls "$home/externals.2.338.0/node24_alpine/bin")" = node ]'
check "externals link untouched"    '[ "$(readlink "$home/externals")" = "$home/externals.2.338.0" ]'
check "six repairs reported"        '[ "$(printf "%s\n" "$out" | grep -c -- "->")" = 6 ]'
check "no temp files left"          '[ -z "$(find "$home" -name ".*.hf-repair.*")" ]'
out2="$("$script" "$home")"
check "second pass is a no-op"      '[ -z "$out2" ]'
check "missing RUNNER_HOME exits 0" '"$script" "$tmp/nope" >/dev/null'
check "--watch rejects bad secs"    '! "$script" --watch x "$home" 2>/dev/null'

exit "$fail"
