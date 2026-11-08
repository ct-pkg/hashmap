#!/usr/bin/env bash
#
# tools/mutation.sh - prove that every gate can fail.
#
#   bash tools/mutation.sh
#   CT=/path/to/ct bash tools/mutation.sh
#
# A gate that has only ever been seen green is not evidence. For each class of
# defect this package claims to reject, this script copies the package into
# $TMPDIR, injects that one defect, and requires the corresponding gate to exit
# non-zero. Three control runs on an unmutated copy must stay green, so a red
# mutation cannot be explained by "the gate always fails".
#
# The original tree is never touched: every case runs on a fresh copy.
#
# Exit status: 0 only when every mutation turns its gate red and every control
# stays green.
#
# License: MIT (see LICENSE).

set -u

pkg="$(cd "$(dirname "$0")/.." && pwd)"
CT="${CT:-$HOME/.local/bin/ct}"
if [ ! -x "$CT" ]; then
    CT=ct
fi
# apply() and the sha256 rewrite are Python; see README §2.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required by tools/mutation.sh (text injection + sha rewrite);" >&2
    echo "see README §2. The package itself does not depend on it." >&2
    exit 1
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

work="${TMPDIR:-/tmp}/ct-hashmap-mut.$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work" || exit 1

fresh() {
    rm -rf "$work/pkg"
    mkdir -p "$work/pkg"
    (cd "$pkg" && tar -cf - --exclude .git .) | tar -xf - -C "$work/pkg"
}

apply() { # apply <file> <old> <new>
    OLD="$2" NEW="$3" FILE="$1" python3 - <<'PY'
import os
path = os.environ["FILE"]
old = os.environ["OLD"]
new = os.environ["NEW"]
with open(path) as fh:
    text = fh.read()
if old not in text:
    raise SystemExit("mutation anchor not found in " + path)
with open(path, "w") as fh:
    fh.write(text.replace(old, new, 1))
PY
}

gate_red() { # gate_red <label> <gate args...>
    label="$1"
    shift
    (cd "$work/pkg" && CT="$CT" bash "$@") >"$work/gate.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "$label -> red (exit $rc)"
    else
        bad "$label" "the gate stayed green"
        tail -n 20 "$work/gate.log" >&2
    fi
}

gate_green() { # gate_green <label> <gate args...>
    label="$1"
    shift
    (cd "$work/pkg" && CT="$CT" bash "$@") >"$work/gate.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$label -> green"
    else
        bad "$label" "the unmutated copy failed its own gate"
        tail -n 20 "$work/gate.log" >&2
    fi
}

shim="hashmap/HashMap.shim.h"
mct="hashmap/HashMap.m.ct"
types="hashmap/HashMapTypes.h.ct"

echo "hashmap mutation gate: $pkg"
echo

echo "== controls (unmutated copy must pass) =="
fresh
gate_green "control mem" tests/mem.sh
fresh
gate_green "control oom" tests/oom.sh
fresh
gate_green "control static" tools/check.sh --static
echo

echo "== leak gates =="
fresh
apply "$work/pkg/$shim" '    /* Overwrite: the previous item came back in spare; release its key copy
     * before the next call reuses spare. */
    free(((ct_hashmap_strint_item *)old)->key);' \
    '    /* mutation: overwrite release removed */'
gate_red "overwrite release removed" tests/mem.sh

fresh
apply "$work/pkg/$shim" '    free(((ct_hashmap_strint_item *)old)->key);
    return CT_HASHMAP_OK;' \
    '    return CT_HASHMAP_OK;'
gate_red "delete release removed" tests/mem.sh

fresh
apply "$work/pkg/$shim" '    ct_hashmap_strint_item *it = (ct_hashmap_strint_item *)item;
    free(it->key);' \
    '    (void)item;'
gate_red "elfree hook neutered" tests/mem.sh

fresh
apply "$work/pkg/$shim" 'static inline void ct_hashmap_strint_iter_release(ct_hashmap_strint_iter *it)
{
    free(it);
}' \
'static inline void ct_hashmap_strint_iter_release(ct_hashmap_strint_iter *it)
{
    (void)it;
}'
gate_red "strint iterator release removed" tests/mem.sh

fresh
apply "$work/pkg/$shim" 'static inline void ct_hashmap_intptr_iter_release(ct_hashmap_intptr_iter *it)
{
    free(it);
}' 'static inline void ct_hashmap_intptr_iter_release(ct_hashmap_intptr_iter *it)
{
    (void)it;
}'
gate_red "intptr iterator release removed" tests/mem.sh
echo

echo "== OOM gate =="
fresh
apply "$work/pkg/$shim" '        if (hashmap_oom(h->map)) {
            ct_hashmap_oom_abort("put");
        }' \
    '        /* mutation: put OOM branch removed */'
gate_red "strint put grow-failure abort removed" tests/oom.sh

fresh
apply "$work/pkg/$shim" '    copy = (char *)CT_HASHMAP_MALLOC(len + 1);
    if (!copy) {
        ct_hashmap_oom_abort("put");
    }' \
    '    copy = (char *)CT_HASHMAP_MALLOC(len + 1);
    /* mutation: key-copy OOM abort removed */'
gate_red "key-copy OOM abort removed" tests/oom.sh

fresh
apply "$work/pkg/$shim" '    it = (ct_hashmap_strint_iter *)CT_HASHMAP_MALLOC(sizeof(*it));
    if (!it) {
        ct_hashmap_oom_abort("iter");
    }' \
    '    it = (ct_hashmap_strint_iter *)CT_HASHMAP_MALLOC(sizeof(*it));
    /* mutation: iterator OOM abort removed */'
gate_red "iterator wrapper OOM abort removed" tests/oom.sh

fresh
apply "$work/pkg/$shim" '    ct_hashmap_strint *h = (ct_hashmap_strint *)CT_HASHMAP_MALLOC(sizeof(*h));
    if (!h) {
        ct_hashmap_oom_abort("new");
    }' \
    '    ct_hashmap_strint *h = (ct_hashmap_strint *)CT_HASHMAP_MALLOC(sizeof(*h));
    /* mutation: wrapper OOM abort removed */'
gate_red "strint wrapper OOM abort removed" tests/oom.sh

fresh
apply "$work/pkg/$shim" '    old = hashmap_set(h->map, &item);
    if (!old && hashmap_oom(h->map)) {
        ct_hashmap_oom_abort("put");
    }' \
    '    old = hashmap_set(h->map, &item);
    (void)old; /* mutation: intptr put OOM abort removed */'
gate_red "intptr put OOM abort removed" tests/oom.sh

fresh
# The suffix (new / put / iter) is diagnostic only; the prefix is the contract.
apply "$work/pkg/$shim" '    fprintf(stderr, "hashmap: out of memory: %s\n", where);' \
    '    fprintf(stderr, "oom: %s\n", where);'
gate_red "OOM prefix changed" tests/oom.sh
echo

echo "== static gates =="
fresh
apply "$work/pkg/$shim" 'static inline int ct_hashmap_strint_len(ct_hashmap_strint *h)' \
    'int ct_hashmap_strint_len(ct_hashmap_strint *h)'
gate_red "shim definition loses static inline" tools/check.sh --static

fresh
apply "$work/pkg/$shim" '#endif /* CT_HASHMAP_SHIM_H */' \
'static inline void ct_hashmap_mut_hook(void)
{
    hashmap_set_allocator(0, 0);
}

#endif /* CT_HASHMAP_SHIM_H */'
gate_red "package installs an allocator hook" tools/check.sh --static

fresh
apply "$work/pkg/$types" '    HMAP_INVALID   = 2' \
'    HMAP_INVALID   = 2,
    HMAP_OOM       = 3'
gate_red "HMAP_OOM reintroduced" tools/check.sh --static

fresh
apply "$work/pkg/$mct" 'pub trait StrIntMap {' \
'pub fn mutatedFree(x int);

pub trait StrIntMap {'
gate_red "a free pub fn appears" tools/check.sh --static

fresh
apply "$work/pkg/$mct" '    HashStrInt *put(const char *key, int value);' \
    '    int put(const char *key, int value);'
gate_red "put stops returning the receiver" tools/check.sh --static

fresh
apply "$work/pkg/README.md" '## 1. 定位与边界' \
'## 0. 多余的章节

struct hashmap *h;

## 1. 定位与边界'
gate_red "README gains a section and leaks a C type" tools/check.sh --static

fresh
apply "$work/pkg/third_party/hashmap.c" '#include "hashmap.h"' \
'#include "hashmap.h"
/* mutation: byte drift */'
gate_red "third_party byte drift" tools/check.sh --static

echo "== contract / type gates =="

fresh
# Both the trait and the shim must lose const; then the compile-fail fixture
# compiles and run.sh has to notice.
apply "$work/pkg/$mct" '    const char *key();' '    char *key();'
apply "$work/pkg/$shim" 'static inline const char *ct_hashmap_strint_iter_key(ct_hashmap_strint_iter *it)' \
    'static inline char *ct_hashmap_strint_iter_key(ct_hashmap_strint_iter *it)'
gate_red "iterator key loses const" tests/run.sh

fresh
# The old gate grepped for "HMAP_OK" and stayed green here: the diagnostic names
# HMAP_OKX, which contains HMAP_OK as a substring.
apply "$work/pkg/tests/compile_fail/enum_needs_types.ct" 'return HMAP_OK;' \
    'return HMAP_OKX;'
gate_red "compile-fail diagnostic is matched exactly" tests/run.sh

fresh
apply "$work/pkg/tests/compile_ok/types_import.ct" 'import hashmap::HashMapTypes;
' ''
gate_red "compile-ok positive control loses its import" tests/run.sh

fresh
apply "$work/pkg/tests/strint.ct" '    if (cond) {
        passed = passed + 1;
    } else {
        failed = failed + 1;
        printf("FAIL %s\n", name);
    }' '    (void)cond;
    (void)name;'
gate_red "assertion floor catches an empty check()" tests/run.sh

fresh
apply "$work/pkg/$shim" '    /* Upstream clamps to [0.50, 0.95] and ignores NaN (hashmap.c:67-79). */
    if (h && h->map) {
        hashmap_set_load_factor(h->map, factor);
    }' '    /* mutation: setLoadFactor is a no-op */
    (void)factor;'
gate_red "setLoadFactor becomes a no-op" tests/run.sh

fresh
apply "$work/pkg/$shim" '    if (h && h->map) {
        hashmap_clear(h->map, true);
    }' '    if (h && h->map) {
        hashmap_clear(h->map, false);
    }'
gate_red "clear() shrinks the bucket array" tests/run.sh

fresh
apply "$work/pkg/$shim" '#define CT_HASHMAP_INVALID    2' \
    '#define CT_HASHMAP_INVALID    7'
gate_red "CT_HASHMAP_INVALID drifts from the enum" tools/check.sh --static

fresh
apply "$work/pkg/README.md" 'h.put("alice", 30).put("bob", 25);' \
    'h.put("alice", 99).put("bob", 25);'
gate_red "README §5/§6 block drifts from docs.ct" tools/check.sh --static

fresh
# Drift block #1, then add a clean block #2 to the same section in both files.
# A checker keyed by section alone would compare only #2 and stay green.
apply "$work/pkg/README.md" 'h.put("alice", 30).put("bob", 25);' \
    'h.put("alice", 99).put("bob", 25);'
apply "$work/pkg/README.md" '### 5.3 覆盖与所有权' '```ct
int extra = 1;
```

### 5.3 覆盖与所有权'
apply "$work/pkg/tests/docs.ct" '    /* ==== README-END §5.2 ==== */
    check(st == HMAP_OK && v == 25, "README 5.2: get bob is 25");' \
    '    /* ==== README-END §5.2 ==== */
    /* ==== README-BEGIN §5.2 ==== */
    int extra = 1;
    /* ==== README-END §5.2 ==== */
    check(extra == 1, "extra");
    check(st == HMAP_OK && v == 25, "README 5.2: get bob is 25");'
gate_red "duplicate §-block cannot hide drift" tools/check.sh --static

fresh
apply "$work/pkg/tests/docs.ct" '/* ==== README-END §6.4 ==== */' \
    '/* mutation: README pairing removed */'
gate_red "missing README block pairing" tools/check.sh --static

fresh
apply "$work/pkg/ct.pkg" 'cflags = -I vendor/hashmap/third_party' \
    'cflags = -I vendor/hashmap'
gate_red "cflags becomes a near-miss path" tools/check.sh --static

fresh
# Remove a declaration the shim needs and update the checksum, so this cannot be
# caught by the byte check instead of the API baseline check.
apply "$work/pkg/third_party/hashmap.h" \
    'size_t hashmap_nbuckets(const struct hashmap *map);' \
    '/* mutation: hashmap_nbuckets declaration removed */'
rel="third_party/hashmap.h" python3 - "$work/pkg" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
rel = os.environ["rel"]
path = os.path.join(root, rel)
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
manifest = os.path.join(root, "tools/third_party.sha256")
lines = []
for line in open(manifest).read().splitlines():
    if line.endswith("  " + rel):
        line = digest + "  " + rel
    lines.append(line)
open(manifest, "w").write("\n".join(lines) + "\n")
PY
gate_red "upstream API baseline loses hashmap_nbuckets" tools/check.sh --static
echo

printf 'hashmap mutation gate: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
