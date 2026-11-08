#!/usr/bin/env bash
#
# tests/mem.sh - the leak gate.
#
#   bash tests/mem.sh
#   MEM_DIFF_KB=64 MEM_ABS_KB=2048 bash tests/mem.sh   # tighter, allowed
#   MEM_DIFF_KB=999999 bash tests/mem.sh               # clamped back to 128
#
# Each mode in tests/mem.ct has a constant footprint by construction, so a leak
# on a write path shows up as a difference between N=1000 and N=10000 while a
# fixed-size table does not. That is why the judge is a differential and not an
# absolute ceiling: a ceiling cannot separate "the table is big" from "the table
# leaks".
#
#   churn   one ~241-byte key overwritten N times    -> the overwrite release
#   del     one key inserted and deleted N times     -> the delete release
#   clear   a 100-key batch inserted and cleared     -> the elfree hook
#   iter    a fixed strint table walked 10xN times   -> the strint iterator wrapper
#   ipiter  a fixed intptr table walked 10xN times   -> the intptr iterator wrapper
#
# A leaked copy is ~241 B per iteration, i.e. ~2.1 MB over the 9000 extra
# iterations, far above allocator noise (measured 0-16 KB on a clean build).
#
# Thresholds may only be tightened: a value above the default is clamped back to
# it, otherwise a leaking package could pass by raising the limit.
#
# Exit status: 0 only when every mode passes both judges.
#
# License: MIT (see LICENSE).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
CT="${CT:-$HOME/.local/bin/ct}"
if [ ! -x "$CT" ]; then
    CT=ct
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

diff_limit="${MEM_DIFF_KB:-128}"
abs_limit="${MEM_ABS_KB:-4096}"
case "$diff_limit" in ''|*[!0-9]*) diff_limit=128 ;; esac
case "$abs_limit" in ''|*[!0-9]*) abs_limit=4096 ;; esac
[ "$diff_limit" -gt 128 ] && diff_limit=128
[ "$abs_limit" -gt 4096 ] && abs_limit=4096

work="${TMPDIR:-/tmp}/ct-hashmap-mem.$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work" || exit 1

(
    cd "$work" || exit 1
    "$CT" build -I "$pkg" \
        --cflags "-I $pkg/third_party -Wall -Wextra" \
        --ldflags "$pkg/third_party/hashmap.c" \
        "$here/mem.ct" -o mem
) >"$work/build.log" 2>&1
if [ $? -ne 0 ]; then
    printf 'mem: build failed\n'
    cat "$work/build.log" >&2
    exit 1
fi
if grep -q 'warning:' "$work/build.log"; then
    bad "mem build warnings" "$(grep -m1 'warning:' "$work/build.log")"
else
    ok "mem build (zero warnings)"
fi

rss_kb() { # rss_kb <mode> <n>; echoes peak RSS in KB, or nothing on failure
    /usr/bin/time -l env HMAP_MEM_MODE="$1" HMAP_MEM_N="$2" "$work/mem" \
        >"$work/$1.$2.out" 2>"$work/$1.$2.err"
    if [ $? -ne 0 ]; then
        return 1
    fi
    if ! grep -qx 'ok' "$work/$1.$2.out"; then
        return 1
    fi
    awk '/maximum resident set size/ { printf "%d\n", int($1 / 1024); exit }' \
        "$work/$1.$2.err"
}

for mode in churn del clear iter ipiter; do
    small="$(rss_kb "$mode" 1000)"
    large="$(rss_kb "$mode" 10000)"
    if [ -z "$small" ] || [ -z "$large" ]; then
        bad "$mode run" "the workload did not finish; see $work/$mode.*.err"
        continue
    fi
    delta=$((large - small))
    if [ "$delta" -le "$diff_limit" ]; then
        ok "$mode differential (delta ${delta} KB <= ${diff_limit} KB)"
    else
        bad "$mode differential" "delta ${delta} KB > ${diff_limit} KB (1000: ${small} KB, 10000: ${large} KB)"
    fi
    if [ "$large" -le "$abs_limit" ]; then
        ok "$mode absolute (${large} KB <= ${abs_limit} KB)"
    else
        bad "$mode absolute" "${large} KB > ${abs_limit} KB"
    fi
done

printf 'mem: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
