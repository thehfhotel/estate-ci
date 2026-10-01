#!/usr/bin/env bash
# Local test for route.sh: builds throwaway git repos and checks the outputs.
# No CI runs this repo's tests; run it by hand after touching route.sh:
#   bash .github/actions/route/test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

SUITES='backend: backend/** Cargo.toml
web: web/** package.json
# comment line
'
DOCS='**/*.md docs/**'
SHARED='.github/workflows/** Cargo.lock'

# A bare "origin" that allows fetching an arbitrary commit with a filter, as
# GitHub does, and a clone of it that mimics actions/checkout (depth 1).
origin="$TMP/origin.git"
git init -q --bare "$origin"
git -C "$origin" config uploadpack.allowAnySHA1InWant true
git -C "$origin" config uploadpack.allowFilter true
work="$TMP/work"
git init -q "$work"
git -C "$work" remote add origin "file://$origin"

commit() { # commit <message> <file>...  (creates/touches each file)
  local msg="$1"
  shift
  local f
  for f in "$@"; do
    mkdir -p "$work/$(dirname "$f")"
    echo "$msg $RANDOM" >>"$work/$f"
  done
  git -C "$work" add -A
  git -C "$work" commit -q -m "$msg"
  git -C "$work" push -q origin HEAD:refs/heads/main --force
  git -C "$work" rev-parse HEAD
}

shallow_clone() { # fresh depth-1 checkout of main into $TMP/co
  rm -rf "$TMP/co"
  git clone -q --depth=1 "file://$origin" "$TMP/co" 2>/dev/null
}

run() { # run <base-sha> -> sets $OUT_TEXT
  shallow_clone
  (cd "$TMP/co" && env -i PATH="$PATH" HOME="$TMP" GITHUB_OUTPUT="$TMP/out" GITHUB_EVENT_NAME=pull_request \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    ROUTE_SUITES="$SUITES" ROUTE_DOCS_GLOBS="$DOCS" ROUTE_SHARED_GLOBS="$SHARED" \
    ROUTE_UNMATCHED="${UNMATCHED:-all}" ROUTE_BASE_SHA="$1" bash "$HERE/route.sh" >"$TMP/log" 2>&1)
  OUT_TEXT="$(cat "$TMP/out" 2>/dev/null)"
  rm -f "$TMP/out"
}

expect() { # expect <name> <needle>...
  local name="$1" n
  shift
  for n in "$@"; do
    if [[ "$OUT_TEXT" != *"$n"* ]]; then
      echo "FAIL: $name: missing '$n'"
      echo "--- output"
      echo "$OUT_TEXT"
      echo "--- log"
      cat "$TMP/log"
      fails=$((fails + 1))
      return
    fi
  done
  echo "ok:   $name"
}

base="$(commit init README.md backend/a.rs web/a.ts Cargo.toml package.json Cargo.lock)"

commit docs README.md docs/x.md >/dev/null
run "$base"
expect "docs only (two commits back)" "docs_only=true" "run_all=false" 'suites={"backend":false,"web":false}'

base="$(git -C "$work" rev-parse HEAD)"
commit be backend/b.rs >/dev/null
run "$base"
expect "backend only" "docs_only=false" "run_all=false" 'suites={"backend":true,"web":false}' 'suite_list=["backend"]'

base="$(git -C "$work" rev-parse HEAD)"
commit both backend/c.rs web/c.ts >/dev/null
run "$base"
expect "both suites" 'suites={"backend":true,"web":true}'

base="$(git -C "$work" rev-parse HEAD)"
commit mixed backend/d.rs README.md >/dev/null
run "$base"
expect "docs ignored next to a code change" 'suites={"backend":true,"web":false}'

base="$(git -C "$work" rev-parse HEAD)"
commit shared Cargo.lock >/dev/null
run "$base"
expect "shared path turns everything on" "run_all=true" 'suites={"backend":true,"web":true}'

base="$(git -C "$work" rev-parse HEAD)"
commit workflow .github/workflows/ci.yml >/dev/null
run "$base"
expect "workflow change runs everything" "run_all=true"

base="$(git -C "$work" rev-parse HEAD)"
commit stray scripts/tool.sh >/dev/null
run "$base"
expect "unclaimed file fails open" "run_all=true" "belongs to no suite"
UNMATCHED=none run "$base"
expect "unclaimed file ignored with unmatched=none" "run_all=false" 'suites={"backend":false,"web":false}'

run 0000000000000000000000000000000000000000
expect "zero base SHA runs everything" "run_all=true" "no base commit"

run ""
expect "empty base runs everything" "run_all=true"

run "1111111111111111111111111111111111111111"
expect "unfetchable base runs everything" "run_all=true" "could not fetch"

run "$(git -C "$work" rev-parse HEAD)"
expect "empty diff runs everything" "run_all=true" "empty diff"

run "not-a-sha"
expect "garbage base runs everything" "run_all=true"

# no suites at all: only the docs short-circuit
SUITES='' run "$(git -C "$work" rev-parse HEAD~1)"
expect "no suites mapped" "docs_only=false" "suites={}" "suite_list=[]"

if [[ $fails -gt 0 ]]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all passed"
