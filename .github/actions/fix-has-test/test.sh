#!/usr/bin/env bash
# Local test for fix-has-test.sh against throwaway git repos. No CI runs it:
#   bash .github/actions/fix-has-test/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
fails=0

DEFAULT_TESTS='**/*.test.*
**/*.spec.*
**/test_*.py
**/*_test.py
**/tests/**
**/__tests__/**
**/e2e/**'
DEFAULT_CODE='**
!docs/**
!**/*.md
!.github/**'

# run_case <name> <title> <body> <expect-exit> <expect-output-regex> <mode> <file[=content]>...
run_case() {
  local name="$1" title="$2" body="$3" want="$4" re="$5" mode="$6"; shift 6
  local r="$TMP/$name"
  git init -q "$r"; (cd "$r"
    echo base >README.txt; git add -A; git commit -qm base; base="$(git rev-parse HEAD)"
    local spec f c
    for spec in "$@"; do
      f="${spec%%=*}"; c="${spec#*=}"; [ "$c" = "$spec" ] && c="x"
      mkdir -p "$(dirname "$f")"; printf '%s\n' "$c" >"$f"
    done
    git add -A; git commit -qm change
    jq -n --arg t "$title" --arg b "$body" '{pull_request:{title:$t,body:$b}}' >"$TMP/$name.json"
    FHT_MODE="$mode" FHT_EVENT_NAME=pull_request FHT_EVENT_PATH="$TMP/$name.json" \
      FHT_TEST_GLOBS="$DEFAULT_TESTS" FHT_CODE_GLOBS="$DEFAULT_CODE" \
      FHT_BASE="$base" FHT_HEAD="$(git rev-parse HEAD)" GITHUB_STEP_SUMMARY="$TMP/$name.sum" \
      bash "$HERE/fix-has-test.sh" >"$TMP/$name.out" 2>&1
    echo $? >"$TMP/$name.rc")
  local rc; rc="$(cat "$TMP/$name.rc")"
  if [ "$rc" = "$want" ] && grep -qE "$re" "$TMP/$name.out"; then
    echo "ok   $name"
  else
    echo "FAIL $name (rc=$rc want=$want, re=$re)"; sed 's/^/     /' "$TMP/$name.out"; fails=$((fails + 1))
  fi
}

run_case with-test    'fix: x' ''  0 'changes code and tests' warn src/a.ts tests/a.test.ts
run_case with-spec-root 'Fix(api): x' '' 0 'changes code and tests' fail src/a.ts a.spec.js
run_case no-test-warn 'fix: x' ''  0 '::warning title=fix-has-test' warn src/a.ts
run_case no-test-fail 'fix(core): x' '' 1 '::error title=fix-has-test' fail src/a.ts
run_case no-test-line 'fix: x' $'blah\r\nno-test: config only\nmore' 0 'notice.*no-test|accepted: no-test: config only' fail src/a.ts
run_case not-fix      'feat: x' '' 0 'not a fix PR' fail src/a.ts
run_case docs-only    'fix: typo' '' 0 'no app code' fail docs/a.txt README.md .github/x.yml
run_case rust-hunk    'fix: x' '' 0 'changes code and tests' fail 'src/lib.rs=fn a(){}
#[test]
fn t(){}'
run_case rust-nohunk  'fix: x' '' 1 '::error' fail 'src/lib.rs=fn a(){}'
run_case inject       'fix: x' '$(touch '"$TMP"'/pwned) `touch '"$TMP"'/pwned2` "; touch '"$TMP"'/pwned3
no-test: $(touch '"$TMP"'/pwned4) `id`' 0 'accepted' fail src/a.ts
for p in pwned pwned2 pwned3 pwned4; do
  if [ -e "$TMP/$p" ]; then echo "FAIL injection: $p created"; fails=$((fails + 1)); fi
done
[ "$fails" = 0 ] && echo "ok   no injection"

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
