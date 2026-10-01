#!/usr/bin/env bash
# Build-time installer for the toolchains listed in toolchains.txt.
# Run by the Dockerfile; see README.md ("Preinstalled toolchains") for why.
#
#   seed-toolchains.sh <manifest>
#
# Layout, per what each setup action looks for:
#   node, python   $TOOLCACHE_ROOT/<Tool>/<version>/x64/ plus a sibling
#                  x64.complete marker: the actions/toolkit tool-cache layout
#                  that setup-node (`node`) and setup-python (`Python`) search
#                  with tc.find() under $RUNNER_TOOL_CACHE.
#   bun            $HF_TOOLCHAIN_DIR/bun/<version>/bun. setup-bun does NOT use
#                  the tool cache: it reuses one binary at ~/.bun/bin/bun.
#
# Env: TOOLCACHE_ROOT (default /opt/hostedtoolcache), HF_TOOLCHAIN_DIR (default
# /opt/hf-toolchains), SEED_VERIFY=0 to skip running the installed binaries (for
# a layout test on a host that cannot execute them), SEED_DRY_RUN=1 to download
# and check every checksum and install nothing.
set -euo pipefail

MANIFEST="${1:?usage: seed-toolchains.sh <manifest>}"
TOOLCACHE_ROOT="${TOOLCACHE_ROOT:-/opt/hostedtoolcache}"
HF_TOOLCHAIN_DIR="${HF_TOOLCHAIN_DIR:-/opt/hf-toolchains}"
VERIFY="${SEED_VERIFY:-1}"
DRY="${SEED_DRY_RUN:-0}"
ARCH=x64

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha256_of() {
  local out
  out="$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" || true
  [[ -n "$out" ]] || out="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  printf '%s' "$out"
}

fetch() { # fetch <url> <sha256> <out>
  curl -fsSL --retry 3 --max-time 600 -o "$3" "$1"
  local got
  got="$(sha256_of "$3")"
  if [[ "$got" != "$2" ]]; then
    echo "seed-toolchains: sha256 mismatch for $1" >&2
    echo "  want $2" >&2
    echo "  got  $got" >&2
    return 1
  fi
}

verify_version() { # verify_version <label> <want> <command...>
  local label="$1" want="$2"
  shift 2
  [[ "$VERIFY" == 1 ]] || return 0
  local got
  got="$("$@" 2>&1 | head -n1)"
  if [[ "$got" != *"$want"* ]]; then
    echo "seed-toolchains: $label reports '$got', expected '$want'" >&2
    return 1
  fi
}

install_bun() { # <version> <archive>
  local dest="$HF_TOOLCHAIN_DIR/bun/$1"
  mkdir -p "$dest"
  unzip -q -o -j "$2" 'bun-linux-x64/bun' -d "$dest"
  chmod 0755 "$dest/bun"
  verify_version "bun $1" "$1" "$dest/bun" --version
}

install_node() { # <version> <archive>
  local dest="$TOOLCACHE_ROOT/node/$1/$ARCH"
  rm -rf "$dest" "$dest.complete"
  mkdir -p "$dest"
  tar -xzf "$2" --strip-components=1 --no-same-owner -C "$dest"
  verify_version "node $1" "v$1" "$dest/bin/node" --version
  touch "$dest.complete"
}

install_python() { # <version> <archive> <url>
  local want_os have_os="" work="$tmp/python-$1"
  want_os="$(printf '%s' "$3" | sed -n 's/.*-linux-\([0-9][0-9.]*\)-x64.*/\1/p')"
  if [[ -r /etc/os-release && "$VERIFY" == 1 ]]; then
    # shellcheck source=/dev/null
    have_os="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    if [[ -n "$want_os" && "$want_os" != "$have_os" ]]; then
      echo "seed-toolchains: python $1 is built for Ubuntu $want_os, this image is $have_os" >&2
      return 1
    fi
  fi
  mkdir -p "$work"
  tar -xzf "$2" --no-same-owner -C "$work"
  # The same script setup-python runs after downloading: it copies into
  # $AGENT_TOOLSDIRECTORY/Python/<version>/x64, creates the python symlinks,
  # upgrades pip and writes the .complete marker. LD_LIBRARY_PATH as setup-python
  # sets it, so the freshly copied interpreter finds its shared library.
  (cd "$work" && AGENT_TOOLSDIRECTORY="$TOOLCACHE_ROOT" LD_LIBRARY_PATH="$work/lib" bash ./setup.sh)
  local dest="$TOOLCACHE_ROOT/Python/$1/$ARCH"
  if [[ ! -e "$dest.complete" ]]; then
    echo "seed-toolchains: python $1 setup.sh did not write $dest.complete" >&2
    return 1
  fi
  verify_version "python $1" "$1" "$dest/bin/python" --version
  rm -rf "$work"
}

count=0
while read -r tool version sha url extra <&3; do
  [[ -z "${tool:-}" || "$tool" == \#* ]] && continue
  if [[ -n "${extra:-}" || -z "${url:-}" ]]; then
    echo "seed-toolchains: bad manifest line for '$tool $version' (want: tool version sha256 url)" >&2
    exit 1
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "seed-toolchains: bad version '$version'" >&2; exit 1; }
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "seed-toolchains: bad sha256 for $tool $version" >&2; exit 1; }
  echo "seed-toolchains: $tool $version"
  archive="$tmp/$tool-$version.archive"
  fetch "$url" "$sha" "$archive"
  if [[ "$DRY" == 1 ]]; then
    rm -f "$archive"
    count=$((count + 1))
    continue
  fi
  case "$tool" in
    bun) install_bun "$version" "$archive" ;;
    node) install_node "$version" "$archive" ;;
    python) install_python "$version" "$archive" "$url" ;;
    *)
      echo "seed-toolchains: unknown tool '$tool' (bun, node, python)" >&2
      exit 1
      ;;
  esac
  rm -f "$archive"
  count=$((count + 1))
done 3<"$MANIFEST"

echo "seed-toolchains: $count toolchain(s) done"
