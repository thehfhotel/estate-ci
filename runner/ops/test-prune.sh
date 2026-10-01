#!/usr/bin/env bash
# Synthetic test of the cache-prune rules in hooks/job-completed.sh: own crates
# keep-newest-K by mtime, third-party artifacts by atime, build-script stems never
# keep-K, the noatime fallback, the freed-space counter. Builds a fake cargo target
# dir under /tmp, touches nothing else, and needs GNU find/touch (run it on Linux,
# for example inside the runner image):
#   docker run --rm --entrypoint bash -v "$PWD/runner:/r:ro" <runner-image> /r/ops/test-prune.sh
# Exits non-zero when a check fails.
set -u
source "${HOOK:-$(dirname "${BASH_SOURCE[0]}")/../hooks/job-completed.sh}"
T=$(mktemp -d /tmp/prunetest.XXXXXX)
P=$T/repo/target-ci/debug
mkdir -p $P/deps $P/build $P/.fingerprint $P/incremental
now=$(date +%s); day=86400
hx() { printf '%016x' "$1"; }
ts() { touch -a -d "@$2" "$1"; touch -m -d "@$3" "$1"; }   # file atime mtime
# top-level own exe
echo x > $P/mycrate; chmod +x $P/mycrate
# own crate: 10 variants, i=1 newest .. 10 oldest (mtime i hours-ish*day), atime = now for all
for i in $(seq 1 10); do
  h=$(hx $((0xa000 + i))); m=$((now - i * 3 * day))
  for f in libmycrate-$h.rlib libmycrate-$h.rmeta; do : > $P/deps/$f; ts $P/deps/$f $now $m; done
  echo "$P/deps/mycrate-$h.d: src/lib.rs src/x.rs" > $P/deps/mycrate-$h.d; ts $P/deps/mycrate-$h.d $now $m
  mkdir -p $P/.fingerprint/mycrate-$h; echo j > $P/.fingerprint/mycrate-$h/lib-mycrate; ts $P/.fingerprint/mycrate-$h/lib-mycrate $now $m; ts $P/.fingerprint/mycrate-$h $now $m
done
# third-party serde: id, mtime days, rlib atime days, fingerprint atime days
tp() { # id mt_days rlib_at_days fp_at_days
  h=$(hx $((0xb000 + $1))); m=$((now - $2 * day)); ar=$((now - $3 * day)); af=$((now - $4 * day))
  : > $P/deps/libserde-$h.rlib; ts $P/deps/libserde-$h.rlib $ar $m
  : > $P/deps/libserde-$h.rmeta; ts $P/deps/libserde-$h.rmeta $ar $m
  echo "$P/deps/serde-$h.d: /cache/registry/src/x/serde-1.0/src/lib.rs" > $P/deps/serde-$h.d; ts $P/deps/serde-$h.d $ar $m
  mkdir -p $P/.fingerprint/serde-$h; echo j > $P/.fingerprint/serde-$h/lib-serde; ts $P/.fingerprint/serde-$h/lib-serde $af $m; ts $P/.fingerprint/serde-$h $af $m
}
tp 1 20 0 0      # HOT: old mtime, used just now                       -> keep
tp 2 20 10 10    # cold 10 days                                        -> delete
tp 3 20 2 2      # used 2 days ago                                     -> keep (3 d rule)
tp 4 0 0 0       # brand new                                           -> keep
tp 5 5 5 5       # cold 5 days                                         -> delete
tp 6 20 10 0     # rlib cold but fingerprint hot (fully fresh build)    -> keep
# build-script stems: 12 variants, all hot atime, old mtime -> all kept (old rule K=8 would drop 4)
for i in $(seq 1 12); do
  h=$(hx $((0xc000 + i))); m=$((now - (20 + i) * day))
  : > $P/deps/build_script_build-$h; ts $P/deps/build_script_build-$h $now $m
  echo "$P/deps/build_script_build-$h.d: /cache/registry/src/x/pkg$i/build.rs" > $P/deps/build_script_build-$h.d; ts $P/deps/build_script_build-$h.d $now $m
  mkdir -p $P/build/pkg$i-$h; echo o > $P/build/pkg$i-$h/output; ts $P/build/pkg$i-$h/output $now $m; ts $P/build/pkg$i-$h $now $m
done
snap() { (cd $P && find deps .fingerprint build -type f | sort); }
cut=$((now - 3600))
echo "== own stems:"; hf_prune_own_stems $P | tr '\n' ' '; echo
echo "== DRY RUN level 1 (K1=8, tp 3 d)"
PRUNE_DRY_RUN=1 hf_prune_root $T/repo/target-ci 1 $cut
before=$(snap | wc -l)
echo "== REAL level 1"
hf_prune_freed_file=$(mktemp); hf_prune_root $T/repo/target-ci 1 $cut
echo "freed counter file: $(awk '{s+=$1} END{print int(s)}' $hf_prune_freed_file) KB over $(wc -l < $hf_prune_freed_file) apply calls"
after=$(snap | wc -l); echo "files before=$before after=$after"
fail=0
chk() { # desc, file glob exists? expect (1/0)
  if ls $P/$2 >/dev/null 2>&1; then got=1; else got=0; fi
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (exists=$got want=$3)"; fail=1; fi
}
chk "serde#1 hot rlib kept"            "deps/libserde-$(hx $((0xb000+1))).rlib" 1
chk "serde#2 cold 10d rlib deleted"    "deps/libserde-$(hx $((0xb000+2))).rlib" 0
chk "serde#2 fingerprint deleted"      ".fingerprint/serde-$(hx $((0xb000+2)))" 0
chk "serde#3 2d kept"                  "deps/libserde-$(hx $((0xb000+3))).rlib" 1
chk "serde#4 new kept"                 "deps/libserde-$(hx $((0xb000+4))).rlib" 1
chk "serde#5 cold 5d deleted"          "deps/libserde-$(hx $((0xb000+5))).rmeta" 0
chk "serde#6 rlib cold, fp hot: kept"  "deps/libserde-$(hx $((0xb000+6))).rlib" 1
chk "build_script 12 variants kept"    "deps/build_script_build-$(hx $((0xc000+12)))" 1
chk "build_script pkg12 build dir"     "build/pkg12-$(hx $((0xc000+12)))" 1
chk "own #8 (8th newest) kept"         "deps/libmycrate-$(hx $((0xa000+8))).rlib" 1
chk "own #9 deleted (keep 8)"          "deps/libmycrate-$(hx $((0xa000+9))).rlib" 0
chk "own #10 deleted"                  "deps/mycrate-$(hx $((0xa000+10))).d" 0
chk "own #10 fingerprint deleted"      ".fingerprint/mycrate-$(hx $((0xa000+10)))" 0
echo "== noatime fallback (fake mountinfo), K1=2, nothing third-party protected by atime"
HF_CI_MOUNTINFO=$T/mi; echo "20 1 8:0 / / rw,noatime - ext4 /dev/x rw" > $T/mi; export HF_CI_MOUNTINFO
PRUNE_DRY_RUN=1 HF_CI_PRUNE_K1=2 hf_prune_root $T/repo/target-ci 1 $cut | head -4
unset HF_CI_MOUNTINFO
echo "== level 3 TP days 0 (emergency): third-party older than min-age atime goes"
PRUNE_DRY_RUN=1 hf_prune_root $T/repo/target-ci 3 $cut | head -12
echo "== tested-tree markers: old files (incl. leftover .tmp.*) go, young ones stay, dir created when missing"
export HF_CI_CACHE=$T/cache; mkdir -p $HF_CI_CACHE/shared
hf_prune_markers >/dev/null; [ -d $HF_CI_CACHE/shared/tested-trees ] && echo "ok   marker dir created" || { echo "FAIL marker dir not created"; fail=1; }
M=$HF_CI_CACHE/shared/tested-trees; mkdir -p $M/o__r
: > $M/o__r/oldtree; : > $M/o__r/.tmp.old123; : > $M/o__r/newtree; : > $M/o__r/.tmp.new456
touch -d "40 days ago" $M/o__r/oldtree $M/o__r/.tmp.old123; touch -d "5 days ago" $M/o__r/newtree $M/o__r/.tmp.new456
hf_prune_markers >/dev/null
for f in oldtree .tmp.old123; do [ ! -e $M/o__r/$f ] && echo "ok   old marker $f removed" || { echo "FAIL $f kept"; fail=1; }; done
for f in newtree .tmp.new456; do [ -e $M/o__r/$f ] && echo "ok   young marker $f kept" || { echo "FAIL $f removed"; fail=1; }; done
rm -rf "$T"
echo "FAIL=$fail"
exit "$fail"
