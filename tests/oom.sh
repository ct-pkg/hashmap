#!/usr/bin/env bash
#
# tests/oom.sh - the OOM contract gate.
#
#   bash tests/oom.sh
#   CT=/path/to/ct bash tests/oom.sh
#
# Builds tests/oom.ct with both fault-injection seams (tests/oom_fixture.h:
# upstream's allocator plus -DCT_HASHMAP_MALLOC for the shim's own mallocs) and
# covers all five abort sites:
#
#   new         install(1)       upstream hashmap_new() fails
#   new-shim    install_shim(1)  the wrapper struct malloc fails
#   put         install(4)       the first resize0() fails
#   put-copy    install_shim(2)  the string-key copy fails
#   put-intptr  install(4)       HashIntPtr's resize fails
#   iter        install_shim(2)  the iterator wrapper fails
#   ok          no injection; the workload must finish normally
#
# Every failing mode must die with SIGABRT and print the fixed prefix
# "hashmap: out of memory: ". The suffix (new / put / iter) is diagnostic only,
# not a contract: `where` exists to locate the site, and tests must not pin
# wording that the contract does not promise.
#
# Exit status: 0 only when every mode behaves as stated.
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

work="${TMPDIR:-/tmp}/ct-hashmap-oom.$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work" || exit 1

# -include makes ct_test_oom_malloc visible before the shim's CT_HASHMAP_MALLOC
# is expanded; the -D alias then routes the shim's three raw allocations here.
cflags="-I $pkg/third_party -I $here -include oom_fixture.h -DCT_HASHMAP_MALLOC=ct_test_oom_malloc -Wall -Wextra"
ldflags="$pkg/third_party/hashmap.c"

(
    cd "$work" || exit 1
    "$CT" build -I "$pkg" --cflags "$cflags" --ldflags "$ldflags" \
        "$here/oom.ct" -o oom
) >"$work/build.log" 2>&1
if [ $? -ne 0 ]; then
    bad "oom build" "see log"
    cat "$work/build.log" >&2
    printf 'oom: %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
if grep -q 'warning:' "$work/build.log"; then
    bad "oom build warnings" "$(grep -m1 'warning:' "$work/build.log")"
else
    ok "oom build (zero warnings)"
fi

run_mode() { # run_mode <mode> <out> <err>; echoes the exit status
    HMAP_FAULT_MODE="$1" "$work/oom" >"$2" 2>"$3"
    echo $?
}

# ---------------- negative control ----------------

rc="$(run_mode ok "$work/ok.out" "$work/ok.err")"
if [ "$rc" -eq 0 ] && grep -qx 'ok' "$work/ok.out"; then
    ok "control mode finishes normally"
else
    bad "control mode" "exit $rc, stdout [$(cat "$work/ok.out")]"
fi

# ---------------- every abort site ----------------

for mode in new new-shim put put-copy put-intptr iter; do
    rc="$(run_mode "$mode" "$work/$mode.out" "$work/$mode.err")"
    if [ "$rc" -eq 134 ]; then
        ok "$mode dies with SIGABRT (status 134)"
    else
        bad "$mode" "exit $rc, expected 134 (SIGABRT)"
    fi
    if grep -q '^hashmap: out of memory: ' "$work/$mode.err"; then
        ok "$mode prints the 'hashmap: out of memory: ' prefix"
    else
        bad "$mode message" "stderr was [$(cat "$work/$mode.err")]"
    fi
    if grep -q 'UNREACHABLE' "$work/$mode.out"; then
        bad "$mode reachable" "the failing path returned instead of aborting"
    fi
done

printf 'oom: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
