/*
 * HashMap.shim.h - the C side of the hashmap package.
 *
 * Two monomorphic shapes over tidwall/hashmap.c, each with its own wrapper and
 * its own item struct:
 *
 *   ct_hashmap_strint   char * key (deep copy, owned) + int value
 *   ct_hashmap_intptr   int key + void * value (borrowed)
 *
 * Each shape is a separate CT host because methods are keyed by (host, name)
 * and the signature does not disambiguate: two `put` overloads on one host
 * would be ambiguous.
 *
 * Ownership, the invariant that costs the most to get wrong:
 *
 *   - upstream copies only `elsize` bytes per item (hashmap.c:124, :286), so a
 *     `char *` key must be copied here; the caller may free its buffer right
 *     after put();
 *   - upstream does NOT call `elfree` on overwrite or delete: it memcpy's the
 *     old item into `map->spare` and returns it (hashmap.c:301-303, :381). So
 *     the old key copy is released here, immediately after the call returns.
 *     One statement later `spare` belongs to the next operation.
 *   - `elfree` runs only from clear() / free() (hashmap.c:192-198), which is
 *     exactly the "whole table goes away" path.
 *   - a `void *` value is copied as a pointer; the pointee is the caller's.
 *
 * OOM contract (design §6): a write either succeeds or the process is already
 * gone. Upstream reports a failed grow through hashmap_oom() (hashmap.c:274-279,
 * :430-432); this shim turns every such branch into
 * `hashmap: out of memory: <where>` + abort(). There is no NULL path that a
 * caller could mistake for success, and no allocator hook is exposed.
 *
 * Everything here is `static inline`, so the unit emits no symbols.
 */
#ifndef CT_HASHMAP_SHIM_H
#define CT_HASHMAP_SHIM_H

#include "hashmap.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Mirror of HashMapStatus in HashMapTypes.h.ct. tools/check.sh compares these
 * against the enum, so the two cannot drift apart silently. */
#define CT_HASHMAP_OK         0
#define CT_HASHMAP_NOT_FOUND  1
#define CT_HASHMAP_INVALID    2

/* Every allocation this shim performs itself (the two wrapper structs, the
 * iterator wrapper, and the string-key copy) goes through this macro. The
 * default is plain malloc; tests/oom.sh compiles with
 * `-DCT_HASHMAP_MALLOC=ct_test_oom_malloc` to fault-inject those sites.
 * Upstream's allocator setter is a process-global and only covers upstream's
 * own allocations, so it cannot reach these. A compile-time seam, not a runtime
 * API: no caller can install it, and the package never touches the upstream
 * allocator. */
#ifndef CT_HASHMAP_MALLOC
#define CT_HASHMAP_MALLOC malloc
#endif

/* Report and terminate. The message is the contract the OOM test asserts on;
 * there is deliberately no return path, because a chained put() has no channel
 * to carry an error (design §6). */
static inline void ct_hashmap_oom_abort(const char *where)
{
    fprintf(stderr, "hashmap: out of memory: %s\n", where);
    fflush(stderr);
    abort();
}

/* ------------------------------------------------------------------ */
/* HashStrInt                                                          */
/* ------------------------------------------------------------------ */

typedef struct ct_hashmap_strint_item {
    char *key;      /* malloc+memcpy copy, owned by the table */
    int value;
} ct_hashmap_strint_item;

typedef struct ct_hashmap_strint {
    struct hashmap *map;
} ct_hashmap_strint;

typedef struct ct_hashmap_strint_iter {
    struct hashmap *map;            /* borrowed */
    size_t cursor;
    ct_hashmap_strint_item *item;   /* borrowed current entry, 0 at end */
} ct_hashmap_strint_iter;

static inline uint64_t ct_hashmap_strint_hash(const void *item, uint64_t seed0,
                                              uint64_t seed1)
{
    const ct_hashmap_strint_item *it = (const ct_hashmap_strint_item *)item;
    return hashmap_sip(it->key, strlen(it->key), seed0, seed1);
}

static inline int ct_hashmap_strint_compare(const void *a, const void *b,
                                            void *udata)
{
    const ct_hashmap_strint_item *x = (const ct_hashmap_strint_item *)a;
    const ct_hashmap_strint_item *y = (const ct_hashmap_strint_item *)b;
    (void)udata;
    return strcmp(x->key, y->key);
}

/* Only reached from hashmap_clear() / hashmap_free(). */
static inline void ct_hashmap_strint_elfree(void *item)
{
    ct_hashmap_strint_item *it = (ct_hashmap_strint_item *)item;
    free(it->key);
}

static inline ct_hashmap_strint *ct_hashmap_strint_new(int capacity,
                                                       long long seed0,
                                                       long long seed1)
{
    ct_hashmap_strint *h = (ct_hashmap_strint *)CT_HASHMAP_MALLOC(sizeof(*h));
    if (!h) {
        ct_hashmap_oom_abort("new");
    }
    h->map = hashmap_new(sizeof(ct_hashmap_strint_item),
                         capacity > 0 ? (size_t)capacity : 0,
                         (uint64_t)seed0, (uint64_t)seed1,
                         ct_hashmap_strint_hash, ct_hashmap_strint_compare,
                         ct_hashmap_strint_elfree, 0);
    if (!h->map) {
        free(h);
        ct_hashmap_oom_abort("new");
    }
    return h;
}

static inline ct_hashmap_strint *ct_hashmap_strint_set_load_factor(
    ct_hashmap_strint *h, double factor)
{
    /* Upstream clamps to [0.50, 0.95] and ignores NaN (hashmap.c:67-79). */
    if (h && h->map) {
        hashmap_set_load_factor(h->map, factor);
    }
    return h;
}

/* Insert or overwrite. A NULL key is ignored: a chained put has no error
 * channel, and the status codes are reserved for the reading calls (see
 * docs/implementation.md, Q1). */
static inline ct_hashmap_strint *ct_hashmap_strint_put(ct_hashmap_strint *h,
                                                       const char *key,
                                                       int value)
{
    ct_hashmap_strint_item item;
    const ct_hashmap_strint_item *old;
    char *copy;
    size_t len;

    if (!h || !h->map || !key) {
        return h;
    }
    len = strlen(key);
    copy = (char *)CT_HASHMAP_MALLOC(len + 1);
    if (!copy) {
        ct_hashmap_oom_abort("put");
    }
    memcpy(copy, key, len + 1);

    /* Zero the whole item: upstream memcpy's `elsize` bytes including the
     * padding between `key` and `value`, and copying an indeterminate byte is
     * undefined. The padding has no meaning to anyone. */
    memset(&item, 0, sizeof(item));
    item.key = copy;
    item.value = value;
    old = (const ct_hashmap_strint_item *)hashmap_set(h->map, &item);
    if (!old) {
        if (hashmap_oom(h->map)) {
            ct_hashmap_oom_abort("put");
        }
        /* New key: the table owns `copy` now. */
        return h;
    }
    /* Overwrite: the previous item came back in spare; release its key copy
     * before the next call reuses spare. */
    free(((ct_hashmap_strint_item *)old)->key);
    return h;
}

static inline int ct_hashmap_strint_get(ct_hashmap_strint *h, const char *key,
                                        int *out)
{
    ct_hashmap_strint_item probe;
    const ct_hashmap_strint_item *found;

    if (!h || !h->map || !key) {
        return CT_HASHMAP_INVALID;
    }
    probe.key = (char *)key;
    probe.value = 0;
    found = (const ct_hashmap_strint_item *)hashmap_get(h->map, &probe);
    if (!found) {
        return CT_HASHMAP_NOT_FOUND;
    }
    if (out) {
        *out = found->value;
    }
    return CT_HASHMAP_OK;
}

static inline int ct_hashmap_strint_del(ct_hashmap_strint *h, const char *key)
{
    ct_hashmap_strint_item probe;
    const ct_hashmap_strint_item *old;

    if (!h || !h->map || !key) {
        return CT_HASHMAP_INVALID;
    }
    probe.key = (char *)key;
    probe.value = 0;
    old = (const ct_hashmap_strint_item *)hashmap_delete(h->map, &probe);
    if (!old) {
        return CT_HASHMAP_NOT_FOUND;
    }
    free(((ct_hashmap_strint_item *)old)->key);
    return CT_HASHMAP_OK;
}

static inline int ct_hashmap_strint_len(ct_hashmap_strint *h)
{
    size_t n;

    if (!h || !h->map) {
        return 0;
    }
    n = hashmap_count(h->map);
    return n > (size_t)0x7fffffff ? 0x7fffffff : (int)n;
}

static inline ct_hashmap_strint *ct_hashmap_strint_clear(ct_hashmap_strint *h)
{
    /* update_cap = true: keep the bucket array so the table can be reused
     * without allocating. update_cap = false would shrink back to `cap`
     * (hashmap.c:207-224), contradicting the documented "keeps buckets".
     * hashmap_clear runs elfree on every item. */
    if (h && h->map) {
        hashmap_clear(h->map, true);
    }
    return h;
}

static inline ct_hashmap_strint_iter *ct_hashmap_strint_iter_new(
    ct_hashmap_strint *h)
{
    ct_hashmap_strint_iter *it;

    if (!h || !h->map) {
        return 0;
    }
    it = (ct_hashmap_strint_iter *)CT_HASHMAP_MALLOC(sizeof(*it));
    if (!it) {
        ct_hashmap_oom_abort("iter");
    }
    it->map = h->map;
    it->cursor = 0;
    it->item = 0;
    return it;
}

static inline int ct_hashmap_strint_iter_next(ct_hashmap_strint_iter *it)
{
    void *item = 0;

    if (!it || !it->map) {
        return 0;
    }
    if (!hashmap_iter(it->map, &it->cursor, &item)) {
        it->item = 0;
        return 0;
    }
    it->item = (ct_hashmap_strint_item *)item;
    return 1;
}

/* const: the key belongs to the table. Handing out a mutable pointer would let
 * a caller overwrite the bytes the table hashes on, silently breaking lookup,
 * deletion and iteration (the table would keep the pointer, not the content).
 * tests/compile_fail/key_write.ct keeps this a compile error. */
static inline const char *ct_hashmap_strint_iter_key(ct_hashmap_strint_iter *it)
{
    return (it && it->item) ? it->item->key : 0;
}

static inline int ct_hashmap_strint_iter_value(ct_hashmap_strint_iter *it)
{
    return (it && it->item) ? it->item->value : 0;
}

static inline void ct_hashmap_strint_iter_release(ct_hashmap_strint_iter *it)
{
    free(it);
}

static inline void ct_hashmap_strint_release(ct_hashmap_strint *h)
{
    if (!h) {
        return;
    }
    hashmap_free(h->map);
    free(h);
}

/* ------------------------------------------------------------------ */
/* HashIntPtr                                                          */
/* ------------------------------------------------------------------ */

typedef struct ct_hashmap_intptr_item {
    int key;
    void *value;
} ct_hashmap_intptr_item;

typedef struct ct_hashmap_intptr {
    struct hashmap *map;
} ct_hashmap_intptr;

typedef struct ct_hashmap_intptr_iter {
    struct hashmap *map;
    size_t cursor;
    ct_hashmap_intptr_item *item;
} ct_hashmap_intptr_iter;

static inline uint64_t ct_hashmap_intptr_hash(const void *item, uint64_t seed0,
                                              uint64_t seed1)
{
    const ct_hashmap_intptr_item *it = (const ct_hashmap_intptr_item *)item;
    return hashmap_murmur(&it->key, sizeof(it->key), seed0, seed1);
}

static inline int ct_hashmap_intptr_compare(const void *a, const void *b,
                                            void *udata)
{
    const ct_hashmap_intptr_item *x = (const ct_hashmap_intptr_item *)a;
    const ct_hashmap_intptr_item *y = (const ct_hashmap_intptr_item *)b;
    (void)udata;
    return (x->key > y->key) - (x->key < y->key);
}

static inline ct_hashmap_intptr *ct_hashmap_intptr_new(int capacity,
                                                       long long seed0,
                                                       long long seed1)
{
    ct_hashmap_intptr *h = (ct_hashmap_intptr *)CT_HASHMAP_MALLOC(sizeof(*h));
    if (!h) {
        ct_hashmap_oom_abort("new");
    }
    /* elfree is 0: the pointee stays with the caller. */
    h->map = hashmap_new(sizeof(ct_hashmap_intptr_item),
                         capacity > 0 ? (size_t)capacity : 0,
                         (uint64_t)seed0, (uint64_t)seed1,
                         ct_hashmap_intptr_hash, ct_hashmap_intptr_compare,
                         0, 0);
    if (!h->map) {
        free(h);
        ct_hashmap_oom_abort("new");
    }
    return h;
}

static inline ct_hashmap_intptr *ct_hashmap_intptr_set_load_factor(
    ct_hashmap_intptr *h, double factor)
{
    if (h && h->map) {
        hashmap_set_load_factor(h->map, factor);
    }
    return h;
}

static inline ct_hashmap_intptr *ct_hashmap_intptr_put(ct_hashmap_intptr *h,
                                                       int key, void *value)
{
    ct_hashmap_intptr_item item;
    const void *old;

    if (!h || !h->map) {
        return h;
    }
    /* Upstream memcpy's `elsize` bytes, padding included (see the strint
     * counterpart). */
    memset(&item, 0, sizeof(item));
    item.key = key;
    item.value = value;
    old = hashmap_set(h->map, &item);
    if (!old && hashmap_oom(h->map)) {
        ct_hashmap_oom_abort("put");
    }
    /* An overwritten pointer value is dropped, not freed: there is no
     * free_fn by design (design §3.3). */
    return h;
}

static inline int ct_hashmap_intptr_get(ct_hashmap_intptr *h, int key,
                                        void **out)
{
    ct_hashmap_intptr_item probe;
    const ct_hashmap_intptr_item *found;

    if (!h || !h->map) {
        return CT_HASHMAP_INVALID;
    }
    probe.key = key;
    probe.value = 0;
    found = (const ct_hashmap_intptr_item *)hashmap_get(h->map, &probe);
    if (!found) {
        return CT_HASHMAP_NOT_FOUND;
    }
    if (out) {
        *out = found->value;
    }
    return CT_HASHMAP_OK;
}

static inline int ct_hashmap_intptr_del(ct_hashmap_intptr *h, int key)
{
    ct_hashmap_intptr_item probe;

    if (!h || !h->map) {
        return CT_HASHMAP_INVALID;
    }
    probe.key = key;
    probe.value = 0;
    if (!hashmap_delete(h->map, &probe)) {
        return CT_HASHMAP_NOT_FOUND;
    }
    return CT_HASHMAP_OK;
}

static inline int ct_hashmap_intptr_len(ct_hashmap_intptr *h)
{
    size_t n;

    if (!h || !h->map) {
        return 0;
    }
    n = hashmap_count(h->map);
    return n > (size_t)0x7fffffff ? 0x7fffffff : (int)n;
}

static inline ct_hashmap_intptr *ct_hashmap_intptr_clear(ct_hashmap_intptr *h)
{
    /* update_cap = true: keep the bucket array (same reason as the strint
     * counterpart). */
    if (h && h->map) {
        hashmap_clear(h->map, true);
    }
    return h;
}

static inline ct_hashmap_intptr_iter *ct_hashmap_intptr_iter_new(
    ct_hashmap_intptr *h)
{
    ct_hashmap_intptr_iter *it;

    if (!h || !h->map) {
        return 0;
    }
    it = (ct_hashmap_intptr_iter *)CT_HASHMAP_MALLOC(sizeof(*it));
    if (!it) {
        ct_hashmap_oom_abort("iter");
    }
    it->map = h->map;
    it->cursor = 0;
    it->item = 0;
    return it;
}

static inline int ct_hashmap_intptr_iter_next(ct_hashmap_intptr_iter *it)
{
    void *item = 0;

    if (!it || !it->map) {
        return 0;
    }
    if (!hashmap_iter(it->map, &it->cursor, &item)) {
        it->item = 0;
        return 0;
    }
    it->item = (ct_hashmap_intptr_item *)item;
    return 1;
}

static inline int ct_hashmap_intptr_iter_key(ct_hashmap_intptr_iter *it)
{
    return (it && it->item) ? it->item->key : 0;
}

static inline void *ct_hashmap_intptr_iter_value(ct_hashmap_intptr_iter *it)
{
    return (it && it->item) ? it->item->value : 0;
}

static inline void ct_hashmap_intptr_iter_release(ct_hashmap_intptr_iter *it)
{
    free(it);
}

static inline void ct_hashmap_intptr_release(ct_hashmap_intptr *h)
{
    if (!h) {
        return;
    }
    hashmap_free(h->map);
    free(h);
}

/* ------------------------------------------------------------------ */
/* Test seam (not part of the CT surface)                              */
/* ------------------------------------------------------------------ */

/* Tests include this header directly to read upstream's bucket count, which is
 * the only way to observe that setLoadFactor actually took effect and that
 * clear() kept the bucket array. There is no CT method for it: the public
 * surface stays the 8 methods per shape. */
static inline size_t hashmap_test_nbuckets(const ct_hashmap_strint *h)
{
    return (h && h->map) ? hashmap_nbuckets(h->map) : 0;
}

#endif /* CT_HASHMAP_SHIM_H */
