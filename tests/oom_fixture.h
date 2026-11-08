/*
 * oom_fixture.h - inject an allocation failure into either allocator.
 *
 * This lives in tests/ and is never part of the package surface: the public
 * API has no allocator hook (design §9), because hashmap_set_allocator() is a
 * process-global and exposing it would let one table change the behaviour of
 * every other table in the process.
 *
 * There are two counters because there are two allocators:
 *
 *   upstream  hashmap.c's own allocations, reached through
 *             hashmap_set_allocator() (install)
 *   shim      the three raw allocations in HashMap.shim.h (wrapper structs,
 *             iterator wrapper, string-key copy), reached by compiling with
 *             -DCT_HASHMAP_MALLOC=ct_test_oom_malloc (install_shim)
 *
 * Both are "the Nth allocation fails", counted from the install call:
 *
 *   install(1)       hashmap_new() fails on its first malloc  -> "out of memory: new"
 *   install(4)       the first resize0() fails on its 4th malloc (map, buckets,
 *                    map2, buckets2)                          -> "out of memory: put"
 *   install_shim(1)  the wrapper struct malloc fails          -> "out of memory: new"
 *   install_shim(2)  the second shim malloc fails: the key copy in put() or the
 *                    iterator wrapper, depending on the mode -> "out of memory: put"
 *                                                                / "out of memory: iter"
 *   install(0) / install_shim(0)  disabled: the negative control
 */
#ifndef CT_HASHMAP_TEST_OOM_H
#define CT_HASHMAP_TEST_OOM_H

#include "hashmap.h"

#include <stddef.h>
#include <stdlib.h>

static int ct_test_oom_upstream_countdown = 0;
static int ct_test_oom_shim_countdown = 0;

static inline void *ct_test_oom_upstream_malloc(size_t size)
{
    if (ct_test_oom_upstream_countdown > 0) {
        ct_test_oom_upstream_countdown = ct_test_oom_upstream_countdown - 1;
        if (ct_test_oom_upstream_countdown == 0) {
            return 0;
        }
    }
    return malloc(size);
}

/* CT_HASHMAP_MALLOC in the shim points here in the OOM build. */
static inline void *ct_test_oom_malloc(size_t size)
{
    if (ct_test_oom_shim_countdown > 0) {
        ct_test_oom_shim_countdown = ct_test_oom_shim_countdown - 1;
        if (ct_test_oom_shim_countdown == 0) {
            return 0;
        }
    }
    return malloc(size);
}

static inline void ct_test_oom_install(int fail_at)
{
    ct_test_oom_upstream_countdown = fail_at;
    ct_test_oom_shim_countdown = 0;
    hashmap_set_allocator(ct_test_oom_upstream_malloc, free);
}

static inline void ct_test_oom_install_shim(int fail_at)
{
    ct_test_oom_upstream_countdown = 0;
    ct_test_oom_shim_countdown = fail_at;
}

#endif /* CT_HASHMAP_TEST_OOM_H */
