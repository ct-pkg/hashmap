#!/usr/bin/env bash
#
# tools/check.sh - the hashmap package gate.
#
#   bash tools/check.sh            full gate
#   bash tools/check.sh --static   sections 1-8 only (no build, no ct get)
#
# Sections:
#
#   1. the delivered file set exists, docs/ has the design and implementation
#      notes, and there is no vendor/ directory;
#   2. ct.pkg keys, `requires = ct >= 0.20.3`, third_party paths, no dep = std;
#   3. third_party/{hashmap.c,hashmap.h,LICENSE} match tools/third_party.sha256
#      byte for byte and the file records the pinned commit;
#   4. public surface: no free `pub fn`, no C type in a CT signature, the four
#      `pub type` aliases point at package handles, the Lib host is exactly the
#      four constructors;
#   5. removed surface: status() / clearStatus() / HMAP_OOM stay gone, the
#      package code never installs an allocator hook;
#   6. HashMapTypes declares exactly HMAP_OK=0 / HMAP_NOT_FOUND=1 /
#      HMAP_INVALID=2, and README names all three;
#   7. every shim definition is static inline (the unit emits no symbols);
#   8. README has exactly ten `## ` sections, includes the glossary section
#      before the limitations section with the three-column table, and no C
#      type leaks into the copy-paste surface;
#   9. tests/mem.sh (1k vs 10k, five modes, two judges each, both shapes);
#  10. installed layout: a real `ct get` copies third_party/, `ct install`
#      prints those flags, and the installed demo builds, runs and diffs;
#  11. --emit-c output includes HashMap.shim.h;
#  12. tests/run.sh (every suite with -Wall -Wextra, compile-fail messages,
#      tests/oom.sh, demo diff).
#
# Exit status: 0 only when every check passes.
#
# License: MIT (see LICENSE).

set -u

static_only=0
if [ "${1:-}" = "--static" ]; then
    static_only=1
fi

pkg="$(cd "$(dirname "$0")/.." && pwd)"
CT="${CT:-$HOME/.local/bin/ct}"
if [ ! -x "$CT" ]; then
    CT=ct
fi
# The enum-mirror and README-block checks are written in Python for correct
# multiline/UTF-8 handling. This is a gate-time prerequisite only: consumers of
# the package need neither python3 nor bash.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required by this gate (enum mirror + README block check);" >&2
    echo "see README §2. The package itself does not depend on it." >&2
    exit 1
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

work="${TMPDIR:-/tmp}/ct-hashmap-check.$$"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work" || exit 1

echo "hashmap gate: $pkg"
echo

echo "== delivered files =="
for f in ct.pkg LICENSE README.md \
         docs/design.md docs/implementation.md \
         hashmap/HashMap.m.ct hashmap/HashMapTypes.h.ct hashmap/HashMap.shim.h \
         third_party/hashmap.c third_party/hashmap.h third_party/LICENSE \
         tools/third_party.sha256 tools/check.sh tools/mutation.sh \
         tests/run.sh tests/oom.sh tests/mem.sh \
         tests/strint.ct tests/copy.ct tests/intptr.ct tests/iter.ct \
         tests/grow.ct tests/loadfactor.ct tests/mem.ct tests/oom.ct \
         tests/oom_fixture.h tests/docs.ct \
         tests/compile_fail/temp_receiver.ct \
         tests/compile_fail/enum_needs_types.ct \
         tests/compile_fail/key_write.ct \
         tests/compile_ok/types_import.ct \
         demo/main.ct demo/expected.out; do
    if [ -f "$pkg/$f" ]; then
        ok "file $f"
    else
        bad "file $f" "missing"
    fi
done
if [ -d "$pkg/vendor" ]; then
    bad "no vendor/ directory" "ct get skips vendor/, so the dependency would vanish"
else
    ok "no package-local vendor/ directory"
fi
echo

echo "== ct.pkg =="
for key in name version licence cflags ldflags requires; do
    if grep -q "^$key[[:space:]]*=" "$pkg/ct.pkg"; then
        ok "ct.pkg has $key"
    else
        bad "ct.pkg $key" "missing"
    fi
done
if grep -qx 'requires = ct >= 0.20.3' "$pkg/ct.pkg"; then
    ok "requires is ct >= 0.20.3"
else
    bad "requires" "expected 'ct >= 0.20.3'"
fi
if grep -q 'third_party/' "$pkg/ct.pkg"; then
    ok "cflags/ldflags point at third_party/"
else
    bad "third_party paths" "ct.pkg does not mention third_party/"
fi
# Exact values, not just the substring: a typo such as `third_party` vs
# `third_party_x` would still pass a grep for third_party/ but break consumers.
if grep -Fxq 'cflags = -I vendor/hashmap/third_party' "$pkg/ct.pkg" &&
   grep -Fxq 'ldflags = vendor/hashmap/third_party/hashmap.c' "$pkg/ct.pkg"; then
    ok "cflags/ldflags are exactly the install paths"
else
    bad "cflags/ldflags" "expected 'cflags = -I vendor/hashmap/third_party' and 'ldflags = vendor/hashmap/third_party/hashmap.c'"
fi
if grep -Eq '^dep[[:space:]]*=[[:space:]]*std([[:space:]]|$)' "$pkg/ct.pkg"; then
    bad "dep = std" "hashmap must not pull std into consumers"
else
    ok "ct.pkg has no dep = std"
fi
if grep -Eq '^licence[[:space:]]*=[[:space:]]*MIT[[:space:]]*$' "$pkg/ct.pkg" &&
   grep -q 'MIT' "$pkg/third_party/LICENSE"; then
    ok "licence field matches the vendored MIT LICENSE"
else
    bad "licence" "ct.pkg says MIT but third_party/LICENSE does not"
fi
echo

echo "== third_party checksums (tidwall/hashmap.c @ 3735986) =="
if (cd "$pkg" && shasum -a 256 -c tools/third_party.sha256 >"$work/sha.log" 2>&1); then
    ok "hashmap.c / hashmap.h / LICENSE match tools/third_party.sha256"
else
    bad "checksums" "see log"
    cat "$work/sha.log" >&2
fi
if grep -q '3735986914fc1c4e6a9123b406d0970666aa4aec' "$pkg/tools/third_party.sha256"; then
    ok "the pinned commit is recorded next to the checksums"
else
    bad "pinned commit" "tools/third_party.sha256 does not record the commit"
fi
# The shim depends on these declarations. Checking them is meaningful even
# though the checksum would also notice a change: a deliberate "upgrade" that
# drops one of them must be caught as a broken assumption, not just as a new
# hash. (A version-macro absence check was empty: upstream has no such macro.)
missing_api=""
for sym in 'hashmap_new(' 'hashmap_set(' 'hashmap_get(' 'hashmap_delete(' \
           'hashmap_iter(' 'hashmap_set_load_factor(' 'hashmap_nbuckets('; do
    if ! grep -Fq "$sym" "$pkg/third_party/hashmap.h"; then
        missing_api="$missing_api $sym"
    fi
done
if [ -z "$missing_api" ]; then
    ok "hashmap.h still declares the 7 symbols the shim relies on"
else
    bad "upstream API baseline" "missing:$missing_api"
fi
echo

echo "== public surface =="
if grep -q '^pub fn ' "$pkg/hashmap/HashMap.m.ct"; then
    bad "no free pub fn" "every method must hang off a type or namespace host"
else
    ok "no free pub fn in HashMap.m.ct"
fi
# Strip comments, `pub type` alias lines and everything right of `->` (the C
# recipe), then no internal C name may remain on the CT surface.
sig="$(awk '
    {
        line = $0
        if (incomment) {
            if (line ~ /\*\//) { sub(/^.*\*\//, "", line); incomment = 0 } else next
        }
        if (line ~ /\/\*/) {
            if (line ~ /\*\//) {
                sub(/\/\*.*\*\//, "", line)
            } else {
                sub(/\/\*.*/, "", line)
                incomment = 1
            }
        }
        sub(/\/\/.*/, "", line)
        if (line ~ /^[[:space:]]*pub[[:space:]]+type[[:space:]]/) next
        sub(/->.*/, "", line)
        print line
    }' "$pkg/hashmap/HashMap.m.ct")"
leak_c="$(printf '%s\n' "$sig" | grep -c 'ct_hashmap_')"
leak_h="$(printf '%s\n' "$sig" | grep -c 'struct hashmap')"
if [ "$leak_c" -eq 0 ] && [ "$leak_h" -eq 0 ]; then
    ok "no ct_hashmap_ / struct hashmap in the public signatures"
else
    bad "C type leak" "ct_hashmap_=$leak_c struct hashmap=$leak_h after stripping aliases and recipes"
fi
for alias in 'HashStrInt = struct ct_hashmap_strint;' \
             'HashIntPtr = struct ct_hashmap_intptr;' \
             'HashStrIntIter = struct ct_hashmap_strint_iter;' \
             'HashIntPtrIter = struct ct_hashmap_intptr_iter;'; do
    if grep -Fq "pub type $alias" "$pkg/hashmap/HashMap.m.ct"; then
        ok "alias: pub type $alias"
    else
        bad "alias: pub type $alias" "missing or does not point at the package handle"
    fi
done
lib_methods="$(awk '
    /^map trait Lib for namespace hashmap/ { inblock = 1; next }
    inblock && /^[[:space:]]*}/ { inblock = 0 }
    inblock {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) {
            sub(/[[:space:]]*\(.*/, "", line)
            print line
        }
    }' "$pkg/hashmap/HashMap.m.ct" | sort | tr '\n' ' ')"
lib_expected="newIntPtr newIntPtrSeeded newStrInt newStrIntSeeded "
if [ "$lib_methods" = "$lib_expected" ]; then
    ok "Lib host is exactly the 4 constructors"
else
    bad "Lib host" "got [$lib_methods], want [$lib_expected]"
fi
for host in 'map trait StrIntMap for type HashStrInt \*' \
            'map trait StrIntIter for type HashStrIntIter \*' \
            'map trait IntPtrMap for type HashIntPtr \*' \
            'map trait IntPtrIter for type HashIntPtrIter \*' \
            'map trait Lib for namespace hashmap'; do
    if grep -Eq "$host" "$pkg/hashmap/HashMap.m.ct"; then
        ok "host: $host"
    else
        bad "host: $host" "missing"
    fi
done
# The chain contract, declared: every writer/configurator returns the receiver.
for sigline in 'HashStrInt *setLoadFactor(double factor);' \
               'HashStrInt *put(const char *key, int value);' \
               'HashStrInt *clear();' \
               'HashIntPtr *setLoadFactor(double factor);' \
               'HashIntPtr *put(int key, void *value);' \
               'HashIntPtr *clear();' \
               'int get(const char *key, int *out);' \
               'int get(int key, void **out);'; do
    if grep -Fq "$sigline" "$pkg/hashmap/HashMap.m.ct"; then
        ok "signature: $sigline"
    else
        bad "signature: $sigline" "not declared"
    fi
done
# HashMapTypes carries enums only.
if grep -Eq '^(pub[[:space:]]+)?(fn|struct|trait|impl|use|const)[[:space:]]' \
        "$pkg/hashmap/HashMapTypes.h.ct"; then
    bad "HashMapTypes" "only enums may live in HashMapTypes.h.ct"
else
    ok "HashMapTypes holds enums only"
fi
echo

echo "== removed surface =="
removed="$(grep -rnE 'HMAP_OOM([^A-Za-z0-9_]|$)|clearStatus|int status\(' \
        "$pkg/hashmap" "$pkg/tests" "$pkg/demo" "$pkg/README.md" 2>/dev/null || true)"
if [ -z "$removed" ]; then
    ok "status() / clearStatus() / HMAP_OOM stay removed"
else
    bad "removed surface" "$(printf '%s' "$removed" | head -3)"
fi
hooks="$(grep -rn 'hashmap_set_allocator' "$pkg/hashmap" 2>/dev/null || true)"
if [ -z "$hooks" ]; then
    ok "the package code installs no allocator hook"
else
    bad "allocator hook" "$(printf '%s' "$hooks" | head -3)"
fi
if grep -rq 'hashmap_scan' "$pkg/hashmap"; then
    bad "hashmap_scan" "the read-only iterator must not fall back to hashmap_scan"
else
    ok "no hashmap_scan in the package code"
fi
echo

echo "== status codes (README vs HashMapStatus) =="
status_names="$(awk '
    /^pub enum HashMapStatus/ { inblock = 1; next }
    inblock && /^}/ { inblock = 0 }
    inblock {
        line = $0
        while (match(line, /HMAP_[A-Z0-9_]+/)) {
            print substr(line, RSTART, RLENGTH)
            line = substr(line, RSTART + RLENGTH)
        }
    }' "$pkg/hashmap/HashMapTypes.h.ct" | sort | tr '\n' ' ')"
status_expected="HMAP_INVALID HMAP_NOT_FOUND HMAP_OK "
if [ "$status_names" = "$status_expected" ]; then
    ok "HashMapStatus declares exactly HMAP_OK / HMAP_NOT_FOUND / HMAP_INVALID"
else
    bad "HashMapStatus codes" "got [$status_names], want [$status_expected]"
fi
if grep -Eq 'HMAP_OK[[:space:]]*=[[:space:]]*0' "$pkg/hashmap/HashMapTypes.h.ct" &&
   grep -Eq 'HMAP_NOT_FOUND[[:space:]]*=[[:space:]]*1' "$pkg/hashmap/HashMapTypes.h.ct" &&
   grep -Eq 'HMAP_INVALID[[:space:]]*=[[:space:]]*2' "$pkg/hashmap/HashMapTypes.h.ct"; then
    ok "the enum values are OK=0 / NOT_FOUND=1 / INVALID=2"
else
    bad "enum values" "expected HMAP_OK=0, HMAP_NOT_FOUND=1, HMAP_INVALID=2"
fi
# The shim's CT_HASHMAP_* macros mirror this enum for C callers. A mirror is
# only safe if it is checked: CT_HASHMAP_INVALID=7 would otherwise pass every
# test (the CT side never reads the macro) while C callers saw the wrong code.
mirror="$(cd "$pkg" && python3 - <<'PY'
import re
enum = open("hashmap/HashMapTypes.h.ct").read()
shim = open("hashmap/HashMap.shim.h").read()
ev = dict(re.findall(r"(HMAP_[A-Z_]+)\s*=\s*(\d+)", enum))
mv = {("HMAP_" + k[len("HASHMAP_"):]): v
      for k, v in re.findall(r"#define\s+CT_(HASHMAP_[A-Z_]+)\s+(\d+)", shim)}
print("yes" if ev and ev == mv else "no:%s vs %s" % (ev, mv))
PY
)"
if [ "$mirror" = "yes" ]; then
    ok "CT_HASHMAP_* mirrors HashMapStatus value for value"
else
    bad "enum mirror" "$mirror"
fi
for code in HMAP_OK HMAP_NOT_FOUND HMAP_INVALID; do
    if grep -Fq "$code" "$pkg/README.md"; then
        ok "README documents $code"
    else
        bad "README $code" "missing from the status table"
    fi
done
echo

echo "== shim linkage =="
shim_bad="$(awk '
    {
        line = $0
        if (incomment) {
            if (line ~ /\*\//) { sub(/^.*\*\//, "", line); incomment = 0 } else next
        }
        if (line ~ /\/\*/) {
            if (line ~ /\*\//) {
                sub(/\/\*.*\*\//, "", line)
            } else {
                sub(/\/\*.*/, "", line)
                incomment = 1
            }
        }
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]/) next
        if (line ~ /^#/) next
        if (line ~ /^typedef /) next
        if (line ~ /^struct /) next
        if (line ~ /^\{/) next
        if (line ~ /^\}/) next
        if (line ~ /^static inline /) next
        print
    }' "$pkg/hashmap/HashMap.shim.h")"
if [ -z "$shim_bad" ]; then
    ok "every shim definition is static inline"
else
    bad "shim linkage" "$(printf '%s' "$shim_bad" | head -3)"
fi
echo

echo "== README =="
sections="$(grep -c '^## ' "$pkg/README.md" 2>/dev/null || true)"
if [ "$sections" = "10" ]; then
    ok "README has exactly 10 sections"
else
    bad "README sections" "found $sections, expected 10"
fi
if grep -qE '^## ([0-9]+\. )?术语表（Glossary）$' "$pkg/README.md"; then
    ok "README has the glossary section"
else
    bad "glossary" "missing '## 术语表（Glossary）'"
fi
if grep -q '^| 术语 | 含义 | 本包中的所指 |$' "$pkg/README.md"; then
    ok "the glossary is a three-column table"
else
    bad "glossary table" "expected '| 术语 | 含义 | 本包中的所指 |'"
fi
gloss_line="$(grep -nE '^## ([0-9]+\. )?术语表（Glossary）$' "$pkg/README.md" | cut -d: -f1)"
limit_line="$(grep -n '^## .*限制' "$pkg/README.md" | head -1 | cut -d: -f1)"
if [ -n "$gloss_line" ] && [ -n "$limit_line" ] && [ "$gloss_line" -lt "$limit_line" ]; then
    ok "the glossary sits before the limitations section"
else
    bad "glossary position" "glossary line [$gloss_line], limitations line [$limit_line]"
fi
# The README quick start must be the compiled demo minus its header comment;
# a drifting copy is how docs start lying.
demo_match="$(cd "$pkg" && python3 - <<'PY'
import re
readme = open("README.md").read()
blocks = re.findall(r"```ct\n(.*?)```", readme, re.S)
demo = open("demo/main.ct").read()
demo = re.sub(r"^/\*.*?\*/\s*", "", demo, count=1, flags=re.S)
print("yes" if blocks and blocks[0].strip() == demo.strip() else "no")
PY
)"
if [ "$demo_match" = "yes" ]; then
    ok "the README quick start is demo/main.ct verbatim (minus its header)"
else
    bad "README quick start" "the first ct block differs from demo/main.ct"
fi
# Every §5 / §6 code block is paired with a README-BEGIN/END region in
# tests/docs.ct, which run.sh compiles and executes. Comparing the text means a
# README edit that looks harmless (alice 30 -> 99) cannot drift from the code
# the tests actually exercise.
block_match="$(cd "$pkg" && python3 - <<'PY'
import re
import textwrap

readme = open("README.md").read()
docs = open("tests/docs.ct").read()

def keyed(items):
    """Key by (section, nth block in that section), not section alone.

    A dict keyed by `§x.y` would silently overwrite the first block when a
    second one appears in the same section, so drift in block #1 could hide
    behind a clean block #2.
    """
    seen = {}
    out = {}
    for sec, text in items:
        seen[sec] = seen.get(sec, 0) + 1
        out["%s#%d" % (sec, seen[sec])] = text
    return out

docs_items = []
for m in re.finditer(
        r"/\* ==== README-BEGIN (§[0-9.]+) ==== \*/\n(.*?)\n[ \t]*/\* ==== README-END \1 ==== \*/",
        docs, re.S):
    docs_items.append((m.group(1), textwrap.dedent(m.group(2)).strip("\n")))

readme_items = []
current = None
ct_blocks = 0
unsectioned = []
lines = readme.splitlines()
i = 0
while i < len(lines):
    # A level-2 heading ends the current §x.y scope; ### starts a new one.
    if re.match(r"^##\s", lines[i]):
        current = None
    h = re.match(r"^### (\d+\.\d+)", lines[i])
    if h:
        current = "§" + h.group(1)
    if re.match(r"^```ct\s*$", lines[i]):
        ct_blocks += 1
        j = i + 1
        body = []
        while j < len(lines) and not re.match(r"^```\s*$", lines[j]):
            body.append(lines[j])
            j += 1
        text = "\n".join(body).strip("\n")
        if current:
            readme_items.append((current, text))
        elif ct_blocks != 1:
            # Only the first block is allowed outside a ### heading: it is the
            # quick start, compared separately against demo/main.ct.
            unsectioned.append(ct_blocks)
        i = j
    i += 1

docs_blocks = keyed(docs_items)
readme_blocks = keyed(readme_items)
missing = sorted(set(docs_blocks) - set(readme_blocks))
extra = sorted(set(readme_blocks) - set(docs_blocks))
drift = sorted(k for k in set(docs_blocks) & set(readme_blocks)
               if docs_blocks[k] != readme_blocks[k])
ok = (len(docs_blocks) >= 11 and len(docs_blocks) == len(readme_blocks)
      and not unsectioned and not missing and not extra and not drift)
print("yes" if ok else
      "no docs=%d readme=%d unsectioned=%s missing=%s extra=%s drift=%s"
      % (len(docs_blocks), len(readme_blocks), unsectioned, missing, extra, drift))
PY
)"
if [ "$block_match" = "yes" ]; then
    ok "every README §5/§6 block matches tests/docs.ct (≥11, keyed by section+ordinal)"
else
    bad "README block drift" "$block_match"
fi
# The glossary is the one place where the C identity is the subject; every
# other section is scanned line by line for the internal names.
leak_pat='ct_hashmap_|struct hashmap'
leaks="$(
    {
        awk '
            /^## / { in_glossary = ($0 ~ /术语表/ || $0 ~ /Glossary/) }
            !in_glossary { print FILENAME ":" FNR "|" $0 }
        ' "$pkg/README.md"
        grep -rEn "$leak_pat" "$pkg/demo" "$pkg/tests" 2>/dev/null || true
    } | grep -E "$leak_pat" || true
)"
if [ -z "$leaks" ]; then
    ok "no internal C names in README examples / demo / tests"
else
    bad "C type leak" "$(printf '%s' "$leaks" | head -3)"
fi
echo

if [ "$static_only" -eq 1 ]; then
    printf 'hashmap gate (static): %d passed, %d failed\n' "$pass" "$fail"
    if [ "$fail" -ne 0 ]; then
        exit 1
    fi
    exit 0
fi

echo "== memory (1k vs 10k, two runs each) =="
if CT="$CT" bash "$pkg/tests/mem.sh" >"$work/mem.log" 2>&1; then
    for mode in churn del clear iter ipiter; do
        for kind in differential absolute; do
            line="$(grep "  ok    $mode $kind" "$work/mem.log" | head -1)"
            if [ -n "$line" ]; then
                ok "${line#  ok    }"
            else
                bad "$mode $kind" "tests/mem.sh printed no decision line"
            fi
        done
    done
else
    bad "tests/mem.sh" "see log"
    cat "$work/mem.log" >&2
fi
echo

echo "== installed layout (real ct get + ct install) =="
if ! command -v "$CT" >/dev/null 2>&1; then
    bad "installed build" "ct not found: $CT"
else
    printf 'name = hashmapconsumer\nversion = 0.1.0\nlicence = MIT\n' > "$work/ct.pkg"
    install_ok=1
    if ! (cd "$work" && "$CT" get "$pkg") >"$work/get.log" 2>&1; then
        bad "ct get" "see log"
        cat "$work/get.log" >&2
        install_ok=0
    elif [ ! -f "$work/vendor/hashmap/third_party/hashmap.c" ] ||
         [ ! -f "$work/vendor/hashmap/third_party/hashmap.h" ]; then
        bad "ct get copy" "third_party/ did not survive the install copy"
        ls -R "$work/vendor/hashmap" >&2
        install_ok=0
    elif [ -d "$work/vendor/hashmap/vendor" ]; then
        bad "ct get copy" "the installed package still carries a vendor/ directory"
        install_ok=0
    else
        ok "ct get copies third_party/ into vendor/hashmap"
    fi
    if [ "$install_ok" -eq 1 ]; then
        if ! (cd "$work" && "$CT" install) >"$work/install.log" 2>&1; then
            bad "ct install" "see log"
            cat "$work/install.log" >&2
            install_ok=0
        elif grep -q 'vendor/hashmap/third_party' "$work/install.log"; then
            ok "ct install prints the third_party flags"
        else
            bad "ct install flags" "third_party missing from the printed command"
            cat "$work/install.log" >&2
            install_ok=0
        fi
    fi
    if grep -q 'vendor/std' "$work/install.log" 2>/dev/null; then
        bad "install flags" "the printed command references vendor/std"
        install_ok=0
    else
        ok "the install command has no vendor/std"
    fi
    if [ "$install_ok" -eq 1 ]; then
        (
            cd "$work" || exit 1
            "$CT" build -I vendor/hashmap \
                --cflags "-I vendor/hashmap/third_party -Wall -Wextra" \
                --ldflags "vendor/hashmap/third_party/hashmap.c" \
                vendor/hashmap/demo/main.ct -o demo_installed
        ) >"$work/installed.log" 2>&1
        if [ $? -eq 0 ] && ! grep -q 'warning:' "$work/installed.log"; then
            if "$work/demo_installed" >"$work/installed.out" 2>&1 &&
               diff -u "$pkg/demo/expected.out" "$work/installed.out" >"$work/installed.diff" 2>&1; then
                ok "install-layout build, run and output"
            else
                bad "install-layout run" "see diff"
                cat "$work/installed.diff" >&2
            fi
        else
            bad "install-layout build" "see log"
            cat "$work/installed.log" >&2
        fi
    fi
fi
echo

echo "== generated C =="
mkdir -p "$work/emit"
if (cd "$pkg" && "$CT" build -I "$pkg" \
        --cflags "-I $pkg/third_party" \
        --ldflags "$pkg/third_party/hashmap.c" \
        --emit-c --outdir "$work/emit" demo/main.ct) >"$work/emit.log" 2>&1; then
    if grep -l 'HashMap.shim.h' "$work/emit"/*.c >/dev/null 2>&1; then
        ok "--emit-c output includes HashMap.shim.h"
    else
        bad "emit-c header" "no generated .c mentions HashMap.shim.h"
        ls -l "$work/emit" >&2
    fi
else
    bad "emit-c build" "see log"
    cat "$work/emit.log" >&2
fi
echo

echo "== suites =="
if CT="$CT" bash "$pkg/tests/run.sh" >"$work/run.log" 2>&1; then
    ok "tests/run.sh ($(tail -n 1 "$work/run.log"))"
else
    bad "tests/run.sh" "see log"
    cat "$work/run.log" >&2
fi
echo

printf 'hashmap gate: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
