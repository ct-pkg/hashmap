# tests

S0 placeholder. No runner yet: the package has no implementation, so there is
nothing to build.

Planned suites (S1, see [../docs/design.md](../docs/design.md) §10):

| Suite | Covers |
| --- | --- |
| `strint.ct` | `HashStrInt`: put / get / del / len / clear, overwrite, missing key |
| `copy.ct` | free the caller's key buffer right after `put`, then `get` still hits (proves the strdup copy) |
| `intptr.ct` | `HashIntPtr`: pointer values are copied shallowly, pointee never freed |
| `iter.ct` | each key visited exactly once; collected-then-deleted recipe |
| `grow.ct` | 100k inserts from capacity 0; every old key readable after resizing |
| `oom.ct` | injected allocator failure: a child process aborts with `hashmap: out of memory: put` (no recoverable OOM) |

`run.sh` will build every suite with `-Wall -Wextra` and fail on any warning.
The leak gate must be proven by mutation: removing the `elfree` hook has to turn
the gate red, otherwise the gate is not evidence.
