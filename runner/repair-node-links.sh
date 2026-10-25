#!/usr/bin/env bash
# hf-repair-node-links: put back the npm / npx / corepack symlinks in the
# runner's bundled Node installs when a runner update has turned them into
# plain file copies.
#
# Why: the actions/runner 2.338.0 self-update unpacked externals.2.338.0 with
# the six links in node20/bin and node24/bin dereferenced. A copied bin/npm is
# npm-cli.js, which does require('../lib/cli.js') relative to ITS OWN path, so
# from node24/bin it looks for node24/lib/cli.js, which does not exist. Every
# job that runs the bundled npm (pnpm/action-setup's self-installer, for one)
# then fails with "Cannot find module '../lib/cli.js'". Seen on hfville
# 2026-10-24; fixed by hand on 2026-10-25 with exactly what this script does.
#
# What it does, for every RUNNER_HOME/externals.*/node*/bin directory:
#   npm      -> ../lib/node_modules/npm/bin/npm-cli.js
#   npx      -> ../lib/node_modules/npm/bin/npx-cli.js
#   corepack -> ../lib/node_modules/corepack/dist/corepack.js
# An entry is replaced only when it is a regular file whose bytes are
# identical to its link target (i.e. a dereferenced copy). Links that are
# already links, missing entries, missing targets and files that differ are
# left alone. The swap is atomic (ln -s to a temp name, then mv -T), so a job
# running at the same moment sees either the old file or the new link.
#
# Usage:
#   hf-repair-node-links [RUNNER_HOME]           one pass, then exit
#   hf-repair-node-links --watch SECS [RUNNER_HOME]
#                                                one pass every SECS seconds,
#                                                forever (self-update happens
#                                                between jobs, without a
#                                                container restart)
# RUNNER_HOME defaults to $RUNNER_HOME, then /runner. Always exits 0 in
# one-pass mode: a failed repair must never stop the runner from starting.

set -u

hf_repair_pass() {
  local home="$1" ext bin pair name target tmp
  for ext in "$home"/externals.*; do
    if [ ! -d "$ext" ] || [ -L "$ext" ]; then continue; fi
    for bin in "$ext"/node*/bin; do
      [ -d "$bin" ] || continue
      for pair in \
        npm:../lib/node_modules/npm/bin/npm-cli.js \
        npx:../lib/node_modules/npm/bin/npx-cli.js \
        corepack:../lib/node_modules/corepack/dist/corepack.js; do
        name="${pair%%:*}"
        target="${pair#*:}"
        if [ ! -f "$bin/$name" ] || [ -L "$bin/$name" ]; then continue; fi
        [ -f "$bin/$target" ] || continue
        cmp -s "$bin/$name" "$bin/$target" || continue
        tmp="$bin/.$name.hf-repair.$$"
        if ln -s "$target" "$tmp" && mv -fT "$tmp" "$bin/$name"; then
          echo "hf-repair-node-links: $bin/$name -> $target"
        else
          rm -f "$tmp"
          echo "hf-repair-node-links: could not repair $bin/$name" >&2
        fi
      done
    done
  done
  return 0
}

if [ "${1:-}" = "--watch" ]; then
  secs="${2:-}"
  case "$secs" in
    '' | *[!0-9]* | 0)
      echo "hf-repair-node-links: --watch needs a whole number of seconds > 0" >&2
      exit 2
      ;;
  esac
  home="${3:-${RUNNER_HOME:-/runner}}"
  while :; do
    hf_repair_pass "$home"
    sleep "$secs"
  done
fi

hf_repair_pass "${1:-${RUNNER_HOME:-/runner}}"
exit 0
