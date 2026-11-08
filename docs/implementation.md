# hashmap 实现说明

- 日期：2026-11-08
- 状态：**S1 实现完成**（可编译、可测、有门禁；已发布 `v0.1.0`）
- 编译器：`ct v0.20.3`（`/Users/samxx/.local/bin/ct`）
- 依据：[design.md](design.md)（S0 需求与设计）
- 上游：[tidwall/hashmap.c](https://github.com/tidwall/hashmap.c) @
  `3735986914fc1c4e6a9123b406d0970666aa4aec`
- 第三方位置：`third_party/`（**不是 `vendor/`**，原因见 §2）

---

## 1. 交付清单

| 交付物 | 位置 | 状态 |
| --- | --- | --- |
| 可编译包 | `ct.pkg`、`hashmap/HashMap.m.ct`、`hashmap/HashMapTypes.h.ct`、`hashmap/HashMap.shim.h` | `ct build` / `ct get` + `ct install` 实测通过 |
| 测试 | `tests/*.ct`、`tests/run.sh` | 7 个套件 + 3 个 compile-fail + 1 个 compile-ok 对照 + OOM 门禁，21 项全绿 |
| 门禁 | `tools/check.sh`（静态 + 全量）、`tests/mem.sh`、`tests/oom.sh` | 全量 102 项全绿 |
| 变异证明 | `tools/mutation.sh` | 3 个对照常绿 + 30 个注入全部变红 |
| 用户文档 | `README.md` | 10 小节，含术语表 |
| 实现说明 | 本文 | — |

不包含（按用户裁定）：发布 tag、`git push`、仓库根 `index/` 的任何改动。

## 2. 文件地图

```text
hashmap/
├── ct.pkg                     # name/version/licence/cflags/ldflags/requires
├── LICENSE                    # 本包 MIT
├── README.md                  # 10 小节用户文档
├── demo/
│   ├── main.ct                # 快速开始；README 第一段代码块即其全文
│   └── expected.out           # 实测输出，run.sh 与安装态各 diff 一次
├── docs/
│   ├── design.md              # S0 需求与设计（只读依据）
│   └── implementation.md      # 本文
├── hashmap/
│   ├── HashMap.m.ct           # 公开面：4 个 pub type + 5 个宿主 + 映射
│   ├── HashMapTypes.h.ct      # pub enum HashMapStatus
│   └── HashMap.shim.h         # 全部 static inline 的 C 包装
├── third_party/
│   ├── hashmap.c              # pinned 上游源码，未修改
│   ├── hashmap.h
│   └── LICENSE
├── tests/                     # 见 §5
└── tools/
    ├── check.sh               # 12 节门禁
    ├── mutation.sh            # 注入缺陷、要求门禁变红
    └── third_party.sha256     # pinned commit + 三个 sha256
```

`third_party/` 的命名是硬约束：`ct get` 的 `copy_tree` 与 `sha_collect` 会静默跳过
名为 `vendor/` 的目录。若把上游源码放进包内 `vendor/`，装到消费者工程后依赖文件会
消失。`tools/check.sh` 第 1 节断言包内没有 `vendor/`，第 10 节用真实
`ct get` + `ct install` 验证 `vendor/hashmap/third_party/hashmap.c` 确实存在。

## 3. 上游事实与实测行号

S0 设计文档引用的行号来自阅读时的上游 `master`，与 pinned commit 有漂移。下表以
**pinned commit 的实际源码**为准；语义与 S0 描述一致，只是行号移动。

| 上游行为 | 实际行号 | 本包如何使用 |
| --- | --- | --- |
| `clamp_load_factor`：NaN 用默认值，否则钳制到 `[0.50, 0.95]` | `:67-73` | `setLoadFactor` 直接透传，不重复钳制 |
| `hashmap_set_load_factor` 写回 `loadfactor/growat` | `:75-79` | 同上 |
| `bucketsz = sizeof(bucket) + elsize` 并对齐指针 | `:124-127` | 决定每个条目的固定大小 |
| `struct hashmap` 分配失败返回 `NULL` | `:130-133` | shim 的 `!h->map` 分支 → `abort()` |
| 桶数组分配失败释放 map 并返回 `NULL` | `:148-152` | 同上 |
| `free_elements`：遍历所有桶调用 `elfree` | `:192-199` | 唯一调用 `elfree` 的地方 |
| `hashmap_clear`：count 清零 → `free_elements` → `update_cap` 为真则保留桶、为假则缩回 `cap` | `:207-224` | shim 用 `update_cap=true`，保留桶数组；`false` 会缩回构造时的 `cap`，与文档相反 |
| `resize0`：失败返回 `false`，成功搬全表 | `:226-261` | 失败由 `hashmap_set` 转成 `oom` |
| `hashmap_set_with_hash`：`oom=false` → 必要时扩容 | `:270-280` | 每次 `put` 的入口 |
| 扩容失败：`map->oom = true; return NULL` | `:276-279` | `put` 检查 `hashmap_oom()` → `abort()` |
| 只拷贝 `elsize` 字节的条目 | `:286` | `char *` 键必须由 shim 深拷贝 |
| 覆盖：旧条目 memcpy 进 `spare` 并返回 | `:301-303` | shim 在返回后立刻 `free` 旧键副本 |
| 删除：旧条目 memcpy 进 `spare` 并返回 | `:381` | 同上 |
| 删除时的缩容失败被忽略（注释说明不影响数据） | `:395-400` | 无需处理：失败只是少缩一次，不是 OOM |
| `hashmap_free`：`free_elements` + 释放桶 + 释放 map | `:421-426` | `release()` 调用 |
| `hashmap_oom` 返回上次 set 的失败标记 | `:430-432` | `put` 区分“新键返回 NULL”与“扩容失败” |
| `hashmap_scan` | `:437-447` | **不使用**；包内改走 `hashmap_iter`，门禁禁止 `hashmap_scan` |
| `hashmap_iter`：光标 `size_t`、返回借用条目 | `:467-476` | 迭代器 shim 的底层 |
| 迭代中删除会重排桶，游标必须重置 | `:459-461`（注释） | 本版不提供遍历中删除 |

## 4. 实现决策

### 4.1 两种形状、四个句柄

| CT 句柄 | C 包装 | 键 / 值 |
| --- | --- | --- |
| `HashStrInt *` | `struct ct_hashmap_strint { struct hashmap *map; }` | `char *` / `int` |
| `HashIntPtr *` | `struct ct_hashmap_intptr { struct hashmap *map; }` | `int` / 借用 `void *` |
| `HashStrIntIter *` | map + `size_t` 光标 + 当前条目指针 | 只读遍历 |
| `HashIntPtrIter *` | 同上 | 只读遍历 |

CT 的方法按（宿主，方法名）唯一，签名不参与重载解析，所以两种形状必须各有自己的
包装结构；一个宿主上放两个 `put` 会歧义。`pub type` 别名把包装结构暴露给 CT，
但不生成 C `typedef`，星号由源码手写。

### 4.2 所有权

- **字符串键**：`put` 里 `malloc(len + 1)` + `memcpy`，表持有副本；调用方在 `put`
  返回后即可释放或改写自己的缓冲区（`tests/copy.ct` 断言）。
- **覆盖**：上游把旧条目放进 `spare` 返回（`:301-303`），shim 立即 `free` 旧键副本；
  晚一步 `spare` 就会被下一次操作覆盖。
- **删除**：同理（`:381`），shim 在 `hashmap_delete` 返回后 `free` 旧键副本。
- **clear / release**：上游 `free_elements` 遍历所有桶调用 `elfree`（`:192-199`），
  shim 的 `elfree` 只释放 `item->key`。
- **`void *` 值**：只拷贝指针；`elfree` 为 `0`，指向对象始终归调用方。覆盖或删除
  指针值时也不释放旧指针。

### 4.3 OOM：进程终止，无静默 NULL

`put` 的返回类型是接收者，没有错误码通道。若扩容失败后“软失败”，链式
`h.put(a).put(b).put(c)` 中间那次写入会静默丢失。因此：

| 失败点 | 行为 |
| --- | --- |
| `malloc` 包装结构失败 | `hashmap: out of memory: new` + `abort()` |
| 上游 `hashmap_new` 返回 `NULL`（map 或桶数组分配失败） | 同上 |
| 键副本 `malloc` 失败 | `hashmap: out of memory: put` + `abort()` |
| `hashmap_set` 返回 `NULL` 且 `hashmap_oom()` 为真 | 同上 |
| 迭代器包装 `malloc` 失败 | `hashmap: out of memory: iter` + `abort()`（见 Q2） |

**五个站点全部有故障注入**（不是只看代码）：

- 上游分配器：`tests/oom_fixture.h` 的 `install(1)` 打到 `new`，`install(4)` 打到
  `put`（第 4 次是首次 `resize0` 的桶数组），另覆盖 `HashIntPtr::put` 的同一条扩容路径；
- shim 自己的三处 `malloc`：`HashMap.shim.h` 的分配统一走编译期宏
  `CT_HASHMAP_MALLOC`，OOM 构建把它指到 `ct_test_oom_malloc`，由 `install_shim(1)`
  覆盖 `new`、`install_shim(2)` 分别覆盖 `put` 的键副本与 `iter` 的包装。
  `hashmap_set_allocator` 是运行时全局且只覆盖上游分配，结构上到不了这三处。

上游 `hashmap_delete` 的缩容失败不置 `oom`（`:395-400`）；那只影响容量，不影响
数据完整性，因此不需要 abort。

### 4.4 空键与 NULL 守卫

- `get` / `del`：句柄或键为 `NULL` → `HMAP_INVALID`，不进入上游。
- `put`：句柄或键为 `NULL` → 直接返回接收者（忽略）。链式写入没有错误通道，
  这比“返回一个调用方无法看到的状态”更诚实。空字符串 `""` **是合法键**，与 `NULL`
  区分（见 Q1）。
- `setLoadFactor` / `clear` 对空句柄是 no-op 并返回接收者。
- `len()` 对空句柄返回 0，并把 `size_t` 钳制到 `INT_MAX`。

### 4.5 迭代器

每个游标是一个独立 `malloc` 的包装，持有 `size_t cursor`；`next()` 调用
`hashmap_iter`，`key()` / `value()` 在游标未定位时返回 `0`。`release()` 只释放游标，
不触碰表与键。顺序不作承诺；遍历中删除会重排桶，故本版不支持，配方是“先收集键、
结束遍历后再删”（README §6.1，`tests/iter.ct` 以 137 个键端到端验证）。

`StrIntIter.key()` 返回 `const char *`：键的字节是表用来哈希与比较的输入，借出可写
指针等于允许调用方静默写坏表（`get` / `del` / 遍历全部失效，`len` 不变）。
`tests/compile_fail/key_write.ct` 把“写入借用键”钉成编译错误。
`key()` 只在 `next()` 返回 1 时有效；之后任何 `put` / `del` / `clear` 都会使其失效，
不承诺仍是原指针。`IntPtrIter.key()` 返回 `int`，合法键 `0` 与“未定位”都得到 `0`，
二者不可区分。

### 4.6 其他

- **`len()` 钳制**：上游 `hashmap_count` 返回 `size_t`，CT 侧是 `int`；超过
  `0x7fffffff` 时返回 `0x7fffffff`，不截断成负数。
- **`clear()` 保留桶数组**：`hashmap_clear(map, true)`，便于“每轮复用同一张表”；
  代价是峰值内存不还给 OS，直到 `release()`。`tests/loadfactor.ct` 用
  `hashmap_test_nbuckets()` 断言 `clear()` 前后桶数不变（`false` 会缩回 16）。
- **只测试可见的桶数读取**：`HashMap.shim.h` 末尾的 `hashmap_test_nbuckets()` 是
  `static inline`，不映射到 CT，公开面仍是每形状 8 个方法；`tests/loadfactor.ct`
  直接 include shim 读取上游 `hashmap_nbuckets()`。
- **padding 归零**：上游按 `elsize` 整体 `memcpy` 条目，结构体 padding 也会被读到；
  `put` 在赋值前 `memset(&item, 0, sizeof item)`，避免复制不确定字节。
- **种子**：非 seeded 构造器固定 `0/0`，可复现；暴露 `*Seeded` 供不可信键场景。
- **负载因子**：不在 shim 重复钳制，上游 `:67-73` 已把 NaN 换成默认值并钳制到
  `[0.50, 0.95]`。
- **不暴露分配器钩子**：`hashmap_set_allocator` 是进程全局；包代码不调用它，
  避免一张表改变同进程其他表的行为。故障注入只存在于 `tests/oom_fixture.h`。

## 5. 测试矩阵

| 套件 | 断言 | 覆盖 |
| --- | --- | --- |
| `tests/strint.ct` | 57 | 构造、put/get/del/len/clear/release、覆盖、空字符串键、NULL 守卫、seeded、容量提示 |
| `tests/copy.ct` | 12 | 释放/改写调用方缓冲区后仍命中；按内容比较；10 万次覆盖、10 万次插入+删除 |
| `tests/intptr.ct` | 44 | NULL 是合法值、指针原样返回、`INT_MIN`/`INT_MAX` 键、迭代 |
| `tests/iter.ct` | 287 | 137 键恰好一次、二次遍历、collect-then-delete、空表 |
| `tests/grow.ct` | 8 | 10 万字符串键扩容后可读、删一半、5 万整数键指针值 |
| `tests/docs.ct` | 16 | README §5/§6 每个 CT 片段可编译并产生所述效果 |
| `tests/loadfactor.ct` | 11 | 0.10→0.50、0.99→0.95、NaN 忽略；`clear()` 保留桶数组 |
| `tests/oom.sh` | 14 | `new` / `new-shim` / `put` / `put-copy` / `put-intptr` / `iter` → 134 + 固定前缀；阴性对照正常结束 |
| `tests/compile_fail/*` | 3 | 临时值链；只 import `HashMap` 时 `HMAP_OK` 不可见；写入借用键是编译错误 |
| `tests/compile_ok/types_import.ct` | 1 | 正向对照：import `HashMapTypes` 后三个状态码可见且编译通过 |

全部套件以 `-Wall -Wextra` 编译，任何 `warning:` 都判失败。每个套件还有最小断言数
（`run.sh` 的 `min_assertions`），把 `check()` 改成空实现会让 `passed=0` 低于下限并判红。
`tests/run.sh` 合计 **21 passed, 0 failed**（含 demo 输出 diff）。

## 6. 门禁实测数据

### 6.1 `tools/check.sh`（12 节）

| 节 | 检查 | 实测 |
| --- | --- | --- |
| 1 | 交付文件集、`docs/` 两份文档、无包内 `vendor/` | 通过 |
| 2 | `ct.pkg` 六个键、`requires = ct >= 0.20.3`、cflags/ldflags **精确值**、无 `dep = std` | 通过 |
| 3 | 三个上游文件逐字节匹配 `tools/third_party.sha256`，记录 pinned commit；shim 依赖的 7 个声明仍在 | 通过 |
| 4 | 无自由 `pub fn`、公开签名无 C 类型、4 个别名、Lib 恰好 4 构造器、8 条链式签名 | 通过 |
| 5 | `status()` / `clearStatus()` / `HMAP_OOM` 不再出现；包内无分配器钩子、无 `hashmap_scan` | 通过 |
| 6 | 枚举恰好 `OK=0 / NOT_FOUND=1 / INVALID=2`；`CT_HASHMAP_*` 逐值镜像枚举；README 三个都写到 | 通过 |
| 7 | shim 的每个定义都是 `static inline` | 通过 |
| 8 | README 恰好 10 节、术语表三列表且在“限制”之前、快速开始与 demo 逐字一致、11 个 §5/§6 块与 `docs.ct` 逐字一致、无 C 类型泄漏 | 通过 |
| 9 | `tests/mem.sh` 五模式 × 两判据（两种形状） | 通过 |
| 10 | 真实 `ct get` 拷贝 `third_party/`、`ct install` 打印 flags、安装态构建/运行/diff | 通过 |
| 11 | `--emit-c` 产物包含 `HashMap.shim.h` | 通过 |
| 12 | `tests/run.sh` | 通过 |

全量输出：`hashmap gate: 102 passed, 0 failed`。

### 6.2 差分内存门禁（1k vs 10k）

| 模式 | 1k → 10k 差分 | 绝对值（10k） | 判据 |
| --- | --- | --- | --- |
| `churn`（strint 同键覆盖） | 0–16 KB | ~1328 KB | 差分 ≤ 128 KB，绝对 ≤ 4096 KB |
| `del`（strint 插入+删除） | -16–0 KB | ~1328 KB | 同上 |
| `clear`（strint 批量插入+清空） | 0–16 KB | ~1376 KB | 同上 |
| `iter`（固定 strint 表反复遍历） | -32–16 KB | ~1360 KB | 同上 |
| `ipiter`（固定 intptr 表反复遍历） | -32–16 KB | ~1360 KB | 同上 |

差分在重复运行间有 0–32 KB 的分配器噪声（负值来自测量时已释放的内存），但都远低于 128 KB。键长约 241 字节；
若每条泄漏一份键副本，9000 次额外迭代会产生约 2.1 MB 差分。
阈值只允许收紧：环境变量给得比默认大时会被钳回默认值，防止“抬高阈值蒙混”。

### 6.3 安装态

`ct get <本地包目录>` 后检查 `vendor/hashmap/third_party/hashmap.c` 与 `.h` 存在、
安装目录内没有嵌套 `vendor/`；`ct install` 打印的命令包含
`vendor/hashmap/third_party` 且不含 `vendor/std`；用打印出的 flags 重新构建
`vendor/hashmap/demo/main.ct`，运行输出与 `demo/expected.out` 逐字一致。

## 7. 变异结果

`bash tools/mutation.sh` 在临时副本上运行，原树不动。3 个对照必须常绿，30 个注入
必须让对应门禁变红：

| 注入缺陷 | 期望变红的门禁 | 实测 |
| --- | --- | --- |
| 覆盖路径不再释放旧键 | `tests/mem.sh` | 红 |
| 删除路径不再释放旧键 | `tests/mem.sh` | 红 |
| `elfree` 空实现 | `tests/mem.sh` | 红 |
| strint 迭代器 `release` 空实现 | `tests/mem.sh` | 红 |
| intptr 迭代器 `release` 空实现 | `tests/mem.sh` | 红 |
| 移除 strint `put` 的扩容 OOM abort | `tests/oom.sh` | 红 |
| 移除键副本 `malloc` 的 OOM abort | `tests/oom.sh` | 红 |
| 移除 strint 迭代器包装的 OOM abort | `tests/oom.sh` | 红 |
| 移除 strint 包装结构的 OOM abort | `tests/oom.sh` | 红 |
| 移除 intptr `put` 的扩容 OOM abort | `tests/oom.sh` | 红 |
| 改写 OOM 固定前缀 | `tests/oom.sh` | 红 |
| shim 定义去掉 `static inline` | `check.sh --static` | 红 |
| 包代码安装分配器钩子 | `check.sh --static` | 红 |
| 回植 `HMAP_OOM` | `check.sh --static` | 红 |
| 增加一个自由 `pub fn` | `check.sh --static` | 红 |
| `put` 改为返回 `int` | `check.sh --static` | 红 |
| README 多一节并泄漏 `struct hashmap` | `check.sh --static` | 红 |
| `third_party/hashmap.c` 字节漂移 | `check.sh --static` | 红 |
| 迭代器 `key()` 去掉 `const` | `tests/run.sh` | 红 |
| compile-fail 的诊断改名为 `HMAP_OKX` | `tests/run.sh` | 红 |
| compile-ok 对照去掉 `HashMapTypes` import | `tests/run.sh` | 红 |
| `check()` 改空实现（断言数 0） | `tests/run.sh` | 红 |
| `setLoadFactor` 改空实现 | `tests/run.sh` | 红 |
| `clear()` 改传 `false`（缩桶） | `tests/run.sh` | 红 |
| `CT_HASHMAP_INVALID` 改成 7 | `check.sh --static` | 红 |
| README 的 `alice 30` 改成 99 | `check.sh --static` | 红 |
| 同节追加第二个块掩盖漂移（§5.2 保留 `alice 99`，再补一个干净块） | `check.sh --static` | 红 |
| 删除 docs.ct 的一个 `README-END` 配对（块数不足） | `check.sh --static` | 红 |
| `cflags` 改成近似路径 | `check.sh --static` | 红 |
| 删除 `hashmap_nbuckets` 声明并同步 sha | `check.sh --static` | 红 |

四个释放路径各自缺失时，差分都会升到约 2.1 MB，远超 128 KB 判据；OOM 分支缺失时
子进程不再以 134 结束或不再打印固定前缀。对照在未变异副本上必须全绿，否则“变红”
不能归因于注入的缺陷。

有三个注入特意绕开“更强的检查”以证明目标检查自己有效：

- 删除 `hashmap_nbuckets` 声明后同步更新 `tools/third_party.sha256`，校验和仍然是
  绿的，只有第 3 节的上游 API 基线检查会红；
- compile-fail 诊断改成 `HMAP_OKX`：旧的 `grep -q 'HMAP_OK'` 会因子串匹配保持绿，
  新的精确文案断言必须红；
- §5.2 保留 `alice 99` 漂移块，再在同节追加一个干净的 `ct` 块：以 `### x.y` 单独作
  键的实现只会比到第二个块而保持绿，按「小节 + 序号」作键并要求块数一致后必须红。

## 8. 裁决记录（2026-11-08）

**Q1（已裁决）：`""` 合法，`NULL` 非法。**
实现与测试原本就是这个语义：shim 只在 `!key` 时拒绝，`tests/strint.ct` 断言
`put("")` / `get("")` / `del("")` 正常、`NULL` 键在 `get` / `del` 返回 `HMAP_INVALID`、
`put` 静默忽略并返回接收者。README §4.2 / §4.6 已写成明确契约；`docs/design.md`
§3.2 / §4 / §6 已统一到此口径并注明修订原因，不再保留「空键非法」的旧表述。

**Q2（已裁决）：接受 `hashmap: out of memory: iter`。**
`where` 用于定位现场，不是契约。README §5.8 把 `new` / `put` / `iter` 标为诊断信息，
并声明三者都是显式 `abort()`、包内没有静默 `NULL` / `0` 失败路径；`tests/oom.sh`
只断言固定前缀 `hashmap: out of memory: `，不绑后缀。

五个 OOM 站点全部有故障注入：上游分配器覆盖 `new`（`install(1)`）与两个形状的
`put`（`install(4)`）；shim 的三处 raw `malloc` 通过 `CT_HASHMAP_MALLOC` 编译期 seam
与 `install_shim(1/2)` 覆盖 `new` / 键副本 `put` / `iter`。
`tools/mutation.sh` 逐个删除 abort 分支都会变红（6 个 OOM 注入）。

**Q3（已记录）：行号只记录，不改语义。**
`docs/design.md` 不再内嵌 `hashmap.c` 行号，统一指向本文 §3 的行号表（只有一份）；
若后续升级 pinned commit，需重新核对该表并更新 `tools/third_party.sha256`。

**第二轮裁决（2026-11-08，对抗评审后）**

- 迭代器 `key()` 由 `char *` 改为 `const char *`，trait 与 shim 同步；写入借用键是
  编译错误（`tests/compile_fail/key_write.ct`）。
- `clear()` 由 `false` 改为 `true`：README / 设计一直写“保留桶数组”，实测
  `false` 会从 32768 桶缩回 16 桶。代价（峰值内存不还给 OS）已写进 README。
- `where` 不是契约：`tests/oom.sh` 只断言 `hashmap: out of memory: ` 前缀；
  README 保留 `new` / `put` / `iter` 三值说明但标注为诊断信息。
- 覆盖边界：五个 OOM 站点全部可注入；内存门禁覆盖两种形状；compile-fail 断言精确
  诊断而非子串；每个套件有最小断言数。

## 9. 验证命令

```bash
cd /Users/samxx/vscspace/ct-pkg/hashmap

bash tests/run.sh          # 7 套件 + 3 compile-fail + 1 compile-ok + OOM + demo，21 项
bash tests/mem.sh          # 5 模式 × 2 判据 + 构建，11 项
bash tools/check.sh        # 12 节全量门禁，102 项
bash tools/check.sh --static   # 只跑 1-8 节，不构建，86 项
bash tools/mutation.sh     # 3 对照 + 30 注入，33 项
```

`CT=/path/to/ct` 可覆盖编译器路径；默认先找 `$HOME/.local/bin/ct`，再退回 PATH
里的 `ct`。所有临时产物落在 `$TMPDIR`，脚本退出时清理。

**门禁前置**：`bash` + `python3`。`tools/check.sh` 用 Python 做枚举镜像比较与
README/`docs.ct` 块比对（需要正确的多行与 UTF-8 处理），`tools/mutation.sh` 用
Python 做文本注入与 sha256 重写。缺 `python3` 时两个脚本都会以非零退出并给出明确
提示（fail-closed）；包本身、`tests/run.sh` 与消费者运行时都不需要它。

## 10. 许可

本包 MIT（见 `LICENSE`）。上游 `hashmap.c` / `hashmap.h` 为
`Copyright (c) 2020 Joshua J Baker`，MIT，原文件与 `third_party/LICENSE` 均保留；
`tools/third_party.sha256` 固定其字节，防止无意的本地修改。
