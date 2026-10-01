#!/usr/bin/env bash
# Runtime step, run by entrypoint.sh as root: copy the toolchains baked into the
# image into the runner's tool cache, for every <tool>/<version> the cache does
# not already hold.
#
#   hf-seed-toolcache <seed-dir> <tool-cache-dir>
#
# Why a copy: compose bind-mounts a host directory over RUNNER_TOOL_CACHE, which
# hides anything the image keeps at that path. The image therefore keeps a seed
# copy elsewhere (default /opt/toolcache-seed) and this fills the mount.
#
# Rules: idempotent; never overwrites (a <tool>/<version>/<arch> that exists in
# any form is left alone); a marker `<arch>.complete` is written only after the
# copy finished, which is what setup-node and setup-python check; one runner at
# a time per cache (flock), because every runner on a host shares the same
# directory. It never fails the container: the cache is an optimisation.
set -uo pipefail

SEED="${1:?usage: hf-seed-toolcache <seed-dir> <tool-cache-dir>}"
CACHE="${2:?usage: hf-seed-toolcache <seed-dir> <tool-cache-dir>}"
OWNER="${HF_TOOLCACHE_OWNER:-runner:runner}"
# Python's pip scripts carry absolute shebangs, and the baked copy was installed
# at this path. Seeding it anywhere else would leave `pip` pointing at the seed.
BAKED="${HF_TOOLCACHE_BAKED_PATH:-/opt/hostedtoolcache}"

[[ -d "$SEED" && -d "$CACHE" ]] || exit 0

seed_all() {
  local marker arch_dir ver_dir tool ver arch dest copied=0
  for marker in "$SEED"/*/*/*.complete; do
    [[ -e "$marker" ]] || continue
    arch_dir="${marker%.complete}"
    [[ -d "$arch_dir" ]] || continue
    ver_dir="$(dirname "$arch_dir")"
    tool="$(basename "$(dirname "$ver_dir")")"
    ver="$(basename "$ver_dir")"
    arch="$(basename "$arch_dir")"
    dest="$CACHE/$tool/$ver/$arch"

    if [[ -e "$dest" || -e "$dest.complete" ]]; then
      continue
    fi
    if [[ "$tool" == Python && "$CACHE" != "$BAKED" ]]; then
      echo "hf-seed-toolcache: skipping Python $ver: baked for $BAKED, tool cache is $CACHE"
      continue
    fi

    mkdir -p "$CACHE/$tool/$ver" || continue
    chown "$OWNER" "$CACHE/$tool" "$CACHE/$tool/$ver" 2>/dev/null
    if cp -a "$arch_dir" "$dest" && cp -a "$marker" "$dest.complete"; then
      echo "hf-seed-toolcache: seeded $tool $ver ($arch)"
      copied=$((copied + 1))
    else
      echo "hf-seed-toolcache: copying $tool $ver failed; removing the partial copy" >&2
      rm -rf "$dest" "$dest.complete"
    fi
  done
  echo "hf-seed-toolcache: $copied toolchain(s) seeded into $CACHE"
}

# The lock lives in the shared cache; the subshell closes it on exit, so it is
# never inherited by the runner process the entrypoint execs afterwards.
(
  flock 9 || exit 0
  seed_all
) 9>"$CACHE/.seed.lock"
exit 0
