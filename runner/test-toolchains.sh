#!/usr/bin/env bash
# Local test for seed-toolchains.sh and seed-toolcache.sh using tiny stand-in
# archives (shell scripts posing as bun, node and python), so it runs anywhere
# without Docker or network. It checks the layout setup-node / setup-python /
# setup-bun look for, checksum enforcement, idempotence and no-overwrite.
# No CI runs this repo's tests; run it by hand after touching either script:
#   bash runner/test-toolchains.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

ok() { echo "ok:   $1"; }
bad() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}
check() { # check <name> <command...>
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ---- stand-in archives ---------------------------------------------------------
mkdir -p "$TMP/arch" && cd "$TMP/arch" || exit 1

mkdir -p bun-linux-x64
printf '#!/bin/sh\necho 1.2.3\n' >bun-linux-x64/bun
chmod +x bun-linux-x64/bun
zip -q -r bun.zip bun-linux-x64

mkdir -p node-v4.5.6-linux-x64/bin
printf '#!/bin/sh\necho v4.5.6\n' >node-v4.5.6-linux-x64/bin/node
chmod +x node-v4.5.6-linux-x64/bin/node
tar -czf node.tar.gz node-v4.5.6-linux-x64

mkdir -p py/bin
printf '#!/bin/sh\necho Python 3.11.99\n' >py/bin/python3.11
chmod +x py/bin/python3.11
cat >py/setup.sh <<'SH'
set -e
V=3.11.99
D="$AGENT_TOOLSDIRECTORY/Python/$V/x64"
mkdir -p "$D"
cp -R ./* "$D"
rm "$D/setup.sh"
ln -s ./bin/python3.11 "$D/python"
ln -s python3.11 "$D/bin/python"
touch "$AGENT_TOOLSDIRECTORY/Python/$V/x64.complete"
SH
tar -czf python.tar.gz -C py .
cd "$HERE" || exit 1

manifest="$TMP/toolchains.txt"
cat >"$manifest" <<EOM
# comment
bun    1.2.3  $(sha "$TMP/arch/bun.zip")  file://$TMP/arch/bun.zip
node   4.5.6  $(sha "$TMP/arch/node.tar.gz")  file://$TMP/arch/node.tar.gz

python 3.11.99 $(sha "$TMP/arch/python.tar.gz")  file://$TMP/arch/python.tar.gz
EOM

# ---- build-time installer -------------------------------------------------------
BAKED="$TMP/baked"
TOOLS="$TMP/hf-toolchains"
if TOOLCACHE_ROOT="$BAKED" HF_TOOLCHAIN_DIR="$TOOLS" bash "$HERE/seed-toolchains.sh" "$manifest" >"$TMP/seed.log" 2>&1; then
  ok "seed-toolchains runs"
else
  bad "seed-toolchains runs"
  cat "$TMP/seed.log"
fi
check "bun at HF_TOOLCHAIN_DIR/bun/<v>/bun" test -x "$TOOLS/bun/1.2.3/bun"
check "node laid out <cache>/node/<v>/x64/bin/node" test -x "$BAKED/node/4.5.6/x64/bin/node"
check "node .complete is a sibling of the arch dir" test -f "$BAKED/node/4.5.6/x64.complete"
check "python at Python/<v>/x64 (capital P)" test -x "$BAKED/Python/3.11.99/x64/bin/python"
check "python .complete" test -f "$BAKED/Python/3.11.99/x64.complete"
check "no setup.sh left in the python dir" test ! -e "$BAKED/Python/3.11.99/x64/setup.sh"

# checksum enforcement
sed 's/^bun    1.2.3  [0-9a-f]\{64\}/bun    1.2.3  0000000000000000000000000000000000000000000000000000000000000000/' "$manifest" >"$TMP/bad.txt"
if TOOLCACHE_ROOT="$TMP/x1" HF_TOOLCHAIN_DIR="$TMP/x2" bash "$HERE/seed-toolchains.sh" "$TMP/bad.txt" >/dev/null 2>&1; then
  bad "a sha256 mismatch fails the build"
else
  ok "a sha256 mismatch fails the build"
fi
check "nothing installed after a mismatch" test ! -e "$TMP/x2/bun"

printf 'ruby 1.0.0 %064d file:///nope\n' 0 >"$TMP/unknown.txt"
if TOOLCACHE_ROOT="$TMP/x1" HF_TOOLCHAIN_DIR="$TMP/x2" bash "$HERE/seed-toolchains.sh" "$TMP/unknown.txt" >/dev/null 2>&1; then
  bad "an unknown tool fails"
else
  ok "an unknown tool fails"
fi

# a binary that reports the wrong version fails verification
printf 'bun 9.9.9 %s file://%s\n' "$(sha "$TMP/arch/bun.zip")" "$TMP/arch/bun.zip" >"$TMP/wrongver.txt"
if TOOLCACHE_ROOT="$TMP/x1" HF_TOOLCHAIN_DIR="$TMP/x3" bash "$HERE/seed-toolchains.sh" "$TMP/wrongver.txt" >/dev/null 2>&1; then
  bad "a wrong reported version fails"
else
  ok "a wrong reported version fails"
fi

# dry run installs nothing
rm -rf "$TMP/x1" "$TMP/x2"
SEED_DRY_RUN=1 TOOLCACHE_ROOT="$TMP/x1" HF_TOOLCHAIN_DIR="$TMP/x2" bash "$HERE/seed-toolchains.sh" "$manifest" >/dev/null 2>&1
check "dry run installs nothing" test ! -e "$TMP/x1" -a ! -e "$TMP/x2"

# ---- runtime seeding ----------------------------------------------------------------
# macOS has no flock(1); a stub is enough, the lock itself is not under test.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/flock"
chmod +x "$TMP/bin/flock"
me="$(id -un):$(id -gn)"

seed() { # seed <cache> [baked]
  PATH="$TMP/bin:$PATH" HF_TOOLCACHE_OWNER="$me" HF_TOOLCACHE_BAKED_PATH="${2:-$1}" \
    bash "$HERE/seed-toolcache.sh" "$BAKED" "$1"
}

CACHE="$TMP/cache"
mkdir -p "$CACHE"
seed "$CACHE" >"$TMP/rt.log" 2>&1
check "node seeded" test -x "$CACHE/node/4.5.6/x64/bin/node" -a -f "$CACHE/node/4.5.6/x64.complete"
check "python seeded when the cache path is the baked path" test -x "$CACHE/Python/3.11.99/x64/bin/python" -a -f "$CACHE/Python/3.11.99/x64.complete"
check "bun is not in the tool cache (setup-bun does not read it)" test ! -e "$CACHE/bun"

# idempotent, and it does not overwrite
echo keep >"$CACHE/node/4.5.6/x64/MARK"
seed "$CACHE" >"$TMP/rt2.log" 2>&1
check "second run changes nothing" test -f "$CACHE/node/4.5.6/x64/MARK"
check "second run reports 0 seeded" grep -q '0 toolchain(s) seeded' "$TMP/rt2.log"

# an existing but incomplete dir is left alone (a setup action may be writing it)
CACHE2="$TMP/cache2"
mkdir -p "$CACHE2/node/4.5.6/x64"
echo partial >"$CACHE2/node/4.5.6/x64/MARK"
seed "$CACHE2" >/dev/null 2>&1
check "an existing dir is never overwritten" test "$(cat "$CACHE2/node/4.5.6/x64/MARK")" = partial
check "...and gets no .complete from us" test ! -e "$CACHE2/node/4.5.6/x64.complete"

# python is skipped when the tool cache is not at the baked path
CACHE3="$TMP/cache3"
mkdir -p "$CACHE3"
seed "$CACHE3" "/opt/hostedtoolcache" >"$TMP/rt3.log" 2>&1
check "node still seeded elsewhere" test -f "$CACHE3/node/4.5.6/x64.complete"
check "python skipped when baked for another path" test ! -e "$CACHE3/Python"
check "...with a message" grep -q 'skipping Python' "$TMP/rt3.log"

# a missing seed or cache is not an error
check "missing seed dir is a no-op" bash "$HERE/seed-toolcache.sh" "$TMP/nope" "$CACHE"

if [[ $fails -gt 0 ]]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all passed"
