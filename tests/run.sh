#!/usr/bin/env bash
#
# tests/run.sh - build and run the hashmap package suites.
#
#   1. builds strint / copy / intptr / iter / grow with -Wall -Wextra and fails
#      on any compiler warning;
#   2. runs each and requires `SUMMARY passed=N failed=0` (and exit 0);
#   3. builds three compile_fail cases, each of which MUST fail with its exact
#      recorded diagnostic, plus one compile_ok positive control that must
#      build (so "always rejects HMAP_OK" cannot pass as evidence);
#   4. runs tests/oom.sh (SIGABRT + fixed prefix, plus a negative control);
#   5. builds demo/main.ct, runs it and diffs the output with demo/expected.out.
#
# Each suite also has a minimum assertion count. An empty check() would print
# `SUMMARY passed=0 failed=0` and exit 0; a floor turns that into a failure.
#
#   bash tests/run.sh
#   CT=/path/to/ct bash tests/run.sh
#
# ct v0.20.3 or newer is required (pub type aliases). All temporary files live
# under $TMPDIR and are removed on exit.
#
# License: MIT (see LICENSE).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
CT="${CT:-$HOME/.local/bin/ct}"
if [ ! -x "$CT" ]; then
    CT=ct
fi

if ! command -v "$CT" >/dev/null 2>&1; then
    echo "ct not found: $CT" >&2
    echo "set CT=/path/to/ct (ct >= 0.20.3, with type aliases)" >&2
    exit 1
fi

work="${TMPDIR:-/tmp}/ct-hashmap-test.$$"
rm -rf "$work"
mkdir -p "$work/roots" || exit 1
ln -s "$pkg/hashmap" "$work/roots/hashmap"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

cflags="-I $pkg/third_party -Wall -Wextra"
ldflags="$pkg/third_party/hashmap.c"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

echo "ct: $(command -v "$CT") ($("$CT" --version 2>/dev/null || true))"
echo "pkg: $pkg"
echo

build() { # build <source> <output> <log>
    (
        cd "$work" || exit 1
        "$CT" build -I "$work/roots" --cflags "$cflags" --ldflags "$ldflags" \
            "$1" -o "$2"
    ) >"$3" 2>&1
}

min_assertions() { # the count the suite had when this floor was written
    case "$1" in
        strint)     echo 57 ;;
        copy)       echo 12 ;;
        intptr)     echo 44 ;;
        iter)       echo 287 ;;
        grow)       echo 8 ;;
        docs)       echo 16 ;;
        loadfactor) echo 11 ;;
        *)          echo 1 ;;
    esac
}

for suite in strint copy intptr iter grow docs loadfactor; do
    echo "== $suite =="
    if ! build "$here/$suite.ct" "$work/$suite" "$work/$suite.build.log"; then
        bad "$suite build" "see log"
        cat "$work/$suite.build.log" >&2
        continue
    fi
    if grep -q 'warning:' "$work/$suite.build.log"; then
        bad "$suite warning" "$(grep -m1 'warning:' "$work/$suite.build.log")"
    else
        ok "$suite build (zero warnings)"
    fi

    "$work/$suite" >"$work/$suite.out" 2>"$work/$suite.err"
    run_rc=$?
    if [ -s "$work/$suite.err" ]; then
        cat "$work/$suite.err" >&2
    fi

    summary="$(sed -n 's/^SUMMARY passed=\([0-9][0-9]*\) failed=\([0-9][0-9]*\)$/\1 \2/p' "$work/$suite.out")"
    if [ -z "$summary" ]; then
        bad "$suite run" "no SUMMARY line (exit $run_rc)"
        cat "$work/$suite.out" >&2
    else
        s_pass="${summary% *}"
        s_fail="${summary#* }"
        floor="$(min_assertions "$suite")"
        if [ "$run_rc" -eq 0 ] && [ "$s_fail" -eq 0 ] && [ "$s_pass" -ge "$floor" ]; then
            ok "$suite assertions ($s_pass passed, floor $floor)"
        else
            bad "$suite assertions" "exit $run_rc, $s_fail failed, $s_pass passed (floor $floor)"
            grep '^FAIL ' "$work/$suite.out" || true
        fi
    fi
    echo
done

echo "== compile_fail =="
expect_compile_fail() { # expect_compile_fail <label> <file> <exact diagnostic>
    label="$1"
    src="$2"
    want="$3"
    log="$work/cf_$label.log"
    if build "$src" "$work/$label" "$log"; then
        bad "$label" "compiled, but this file must be rejected"
    elif grep -Fq "$want" "$log"; then
        ok "$label rejected with the recorded diagnostic"
    else
        bad "$label" "failed with a different diagnostic; want [$want]"
        cat "$log" >&2
    fi
}

expect_compile_fail temp_receiver "$here/compile_fail/temp_receiver.ct" \
    'a method call on a temporary is only allowed at the start of a statement or of an assignment'
# ct v0.20.3 prints exactly this for an undeclared enum constant. Matching only
# "HMAP_OK" would stay green even if the file imported HashMapTypes and failed
# for an unrelated reason.
expect_compile_fail enum_needs_types "$here/compile_fail/enum_needs_types.ct" \
    "error: use of undeclared identifier 'HMAP_OK'"
# Writing through the borrowed key must be a type error, not a silent table
# corruption.
expect_compile_fail key_write "$here/compile_fail/key_write.ct" \
    'error: read-only variable is not assignable'

# Positive control: with HashMapTypes imported, HMAP_OK must compile.
if build "$here/compile_ok/types_import.ct" "$work/types_import" "$work/cf_ok.log"; then
    if grep -q 'warning:' "$work/cf_ok.log"; then
        bad "types_import warning" "$(grep -m1 'warning:' "$work/cf_ok.log")"
    else
        ok "importing HashMapTypes makes HMAP_OK compile"
    fi
else
    bad "types_import" "the positive control did not compile; see log"
    cat "$work/cf_ok.log" >&2
fi
echo

echo "== oom =="
if CT="$CT" bash "$here/oom.sh" >"$work/oom.log" 2>&1; then
    ok "tests/oom.sh ($(tail -n 1 "$work/oom.log"))"
else
    bad "tests/oom.sh" "see log"
    cat "$work/oom.log" >&2
fi
echo

echo "== demo =="
if ! build "$pkg/demo/main.ct" "$work/demo" "$work/demo.build.log"; then
    bad "demo build" "see log"
    cat "$work/demo.build.log" >&2
else
    if grep -q 'warning:' "$work/demo.build.log"; then
        bad "demo warning" "$(grep -m1 'warning:' "$work/demo.build.log")"
    else
        ok "demo build (zero warnings)"
    fi
    "$work/demo" >"$work/demo.out" 2>&1
    if diff -u "$pkg/demo/expected.out" "$work/demo.out" >"$work/demo.diff" 2>&1; then
        ok "demo output matches expected.out"
    else
        bad "demo output" "diff vs expected.out"
        cat "$work/demo.diff" >&2
    fi
fi
echo

printf 'hashmap: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
