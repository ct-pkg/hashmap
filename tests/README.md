# tests

每个套件都是独立的 ct 程序，`main` 里用 `check()` 累计断言，末行固定打印
`SUMMARY passed=N failed=0`。`tests/run.sh` 负责编译（`-Wall -Wextra`，任何
`warning:` 都判失败）、运行、核对 SUMMARY，并串起编译失败用例、OOM 门禁与 demo。
每个套件还有一个最小断言数（见 `run.sh` 的 `min_assertions`）：把 `check()` 改成
空实现会打印 `passed=0`，低于下限即判红。

| 套件 | 断言 | 覆盖 |
| --- | --- | --- |
| `strint.ct` | 57 | 构造 / put / get / del / len / clear / release、覆盖、空字符串键、NULL 守卫、seeded 构造器、容量提示 |
| `copy.ct` | 12 | `put` 后释放或改写调用方缓冲区仍能命中；键按内容而非指针比较；10 万次覆盖与 10 万次插入+删除 |
| `intptr.ct` | 44 | `void *` 值浅拷贝、`NULL` 是合法值、指针原样返回、`INT_MIN` / `INT_MAX` 键、迭代 |
| `iter.ct` | 287 | 137 个键恰好各访问一次、二次遍历、collect-then-delete 配方、空表 |
| `grow.ct` | 8 | 从容量 0 起 10 万字符串键、删一半、5 万整数键，扩容后旧键全部可读 |
| `docs.ct` | 16 | README §5 / §6 的每个 CT 片段（`snippet_*` / `recipe_*`）可编译并产生所述效果；`check.sh` 逐块比对 README 与 `README-BEGIN/END` 标记之间的文本 |
| `loadfactor.ct` | 10 | `setLoadFactor` 的钳制（0.10→0.50、0.99→0.95、NaN 忽略）与 `clear()` 保留桶数组，用仅测试可见的 `hashmap_test_nbuckets()` 读取 |
| `mem.ct` | — | `tests/mem.sh` 的五种恒定足迹负载：`churn` / `del` / `clear` / `iter` / `ipiter` |
| `oom.ct` | — | `tests/oom.sh` 的故障注入程序，见 `oom_fixture.h`；覆盖 5 个 abort 站点 + 阴性对照 |

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `run.sh` | 上表七个套件 + 三个 compile-fail + 一个 compile-ok 对照 + `oom.sh` + demo 输出 diff |
| `oom.sh` | `new` / `new-shim` / `put` / `put-copy` / `put-intptr` / `iter` 六种注入必须 SIGABRT（134）且 stderr 以固定前缀开头，另有正常结束的阴性对照 |
| `mem.sh` | 1k vs 10k 峰值 RSS 差分（默认 ≤ 128 KB，只许收紧），另加 4096 KB 绝对上限；两种形状都覆盖 |

## 编译失败用例

| 文件 | 期望 |
| --- | --- |
| `compile_fail/temp_receiver.ct` | 以自写 CT 函数为根、把链当实参，必须报 `a method call on a temporary is only allowed at the start of a statement or of an assignment` |
| `compile_fail/enum_needs_types.ct` | 只 import `hashmap::HashMap` 时 `HMAP_OK` 未声明，必须报 `error: use of undeclared identifier 'HMAP_OK'`（不是只 grep 名字） |
| `compile_fail/key_write.ct` | `it.key()[0] = 'X'` 必须报 `error: read-only variable is not assignable`，证明借出的键只读 |
| `compile_ok/types_import.ct` | 正向对照：同时 import 两个单元后 `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID` 必须编译通过 |

`tools/mutation.sh` 会把这些门禁逐条注入缺陷并验证变红；只报 pass 不算证据。
