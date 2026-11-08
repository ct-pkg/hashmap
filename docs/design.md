# hashmap 模块需求与设计（S0）

- 日期：2026-11-08
- 状态：**需求与骨架**。本轮不写实现、不拷第三方源码、不发布 tag
- 目标包：`hashmap`（`ct-pkg/hashmap`），仓库 https://github.com/ct-pkg/hashmap
- 上游：https://github.com/tidwall/hashmap.c ，核对基线 commit
  `3735986914fc1c4e6a9123b406d0970666aa4aec`（2026-11-08 的 `master`）
- 选型依据：`ct/docs/design/map-options.md`（提交 `c568c71`）§3.B / §4 / §6.S1

---

## 0. 结论摘要

1. **定位不变**：动态增长、Robin Hood 开放寻址、条目**拷贝**进表、单文件、MIT。
   与 `std::map`（定容、不 rehash）和 `dict`（只存指针、增量 rehash）并列，不合并接口。
2. **两种形状**：`HashStrInt`（`char *` → `int`）与 `HashIntPtr`（`int` → `void *`），
   与 `std::map` 的 `MapStrInt` / `MapIntPtr` 对齐，便于同一场景对照迁移。
3. **"拷贝"要拆开讲**：上游只拷贝 `elsize` 字节的条目结构，**不深拷贝键指向的内容**。
   因此 `char *` 键由 shim 用 `strdup` 深拷贝；`clear()` / `release()` 靠 `elfree` 回收，
   而**覆盖与删除不调用 `elfree`**（上游把旧条目拷进 `spare` 返回，`hashmap.c:351-371`），
   必须由 shim 在调用返回后释放旧条目里的键副本。`void *` 值只拷贝指针本身，
   指向的对象仍归调用方。这条必须在 README 第一屏出现。
4. **OOM = 进程终止**（与 `dict` 的共同契约，见 §6）。
   - 检出点：`hashmap_set` 返回 `NULL` 时无法区分"键是新的"与"分配失败"，只有
     `hashmap_oom()` 能区分（`hashmap.c:293-296`, `:394-398`）。shim 在**每次** `put`
     调用 `hashmap_set` 之后立即检查：结果为 `NULL` 且 `hashmap_oom()` 为真，就向 stderr
     打印 `hashmap: out of memory: put` 并 `abort()`。
   - 公开面因此没有 `status()` / `clearStatus()`，也没有粘性状态机。链式
     `t.put(a).put(b).put(c)` 的每一步要么成功，要么进程已经结束，不存在"中途丢了、
     调用方不知道"的中间态。
   - **为何选终止**：链式 `put` 返回接收者本身，没有错误码通道。被否决的软失败方案有两条：
     （a）粘性状态 + `clearStatus()`——中间失败在链上看不见，只能事后 `status()`，错误被
     推迟且更难定位，还多两个方法、一个状态字段与每条写入一次分支；
     （b）把 `put` 改成返回 `int`——放弃链式，与 ct-pkg 的 OO 默认准则冲突（裁决 D-1），
     并且每个调用点都要写检查。三种方案的代价对比见 §6。
   - 结论：**调用方不需要、也不能处理 OOM**。容器写入路径上不存在可恢复的 OOM，
     与 `dict` 完全一致（`dict/docs/design.md` §6 是本契约的另一半）。
5. **迭代只读**：上游明确写了"迭代中 `hashmap_delete` 会重排桶，游标必须重置"
   （`hashmap.c:413-424`）。v1 不提供迭代中删除；需要删除时先收集键，结束后再删。
6. **不提供自动析构**：包只给显式 `release()`；`impl Drop` 由调用方单元自己写（内建 `Drop`
   发射为 `static`，包单元不可见）。
7. **公开面零 C 类型**：两个句柄都是 `pub type ... = struct ct_hashmap_*;` 的包装结构，
   `struct hashmap` 只出现在 shim 里。不新增 `void *` 宿主。
8. **许可**：上游 MIT（`Copyright (c) 2020 Joshua J Baker`，2026-11-08 读其 `LICENSE` 原文），
   保留 `LICENSE` 与源文件头。`requires = ct >= 0.20.3`（依赖 `pub type`），S1 需实测。

---

## 1. 场景与判据

`hashmap` 覆盖"容量未知、希望调用方写完就能放手"的通用业务表。

| 场景 | 选 `std::map` | 选 `hashmap` | 选 `dict` |
| --- | --- | --- | --- |
| 容量 `init` 时能定死，`put` 不许分配 | ✅ 唯一 | ❌ | ❌ |
| 规模未知，键值交给容器持有 | ❌ 会满 | ✅ 首选 | ⚠️ 需自己管键值 |
| 十万级以上、扩容不能有长停顿 | ❌ | ⚠️ 扩容是一次性搬全表 | ✅ |
| 遍历中删除 | ❌ 无遍历 | ❌ v1 不支持 | ✅ safe iterator |
| 想少一个第三方依赖 | ✅ | ✅ 单文件 | ❌ |

判据只有两条是调用方可见的语义：**键值是否被拷贝**、**扩容是否会造成长停顿**。
本包在前者是"拷贝"（按键值形状定义，见 §3），在后者是"一次性扩容"。

---

## 2. 句柄与宿主

| CT 句柄 | C 侧包装 | 宿主 | 说明 |
| --- | --- | --- | --- |
| `HashStrInt *` | `struct ct_hashmap_strint { struct hashmap *h; }` | `HashStrInt *` | `char *` → `int` |
| `HashIntPtr *` | `struct ct_hashmap_intptr { struct hashmap *h; }` | `HashIntPtr *` | `int` → `void *` |
| `HashStrIntIter *` | 游标 + 当前 item 指针 | `HashStrIntIter *` | 只读遍历 |
| `HashIntPtrIter *` | 同上 | `HashIntPtrIter *` | 只读遍历 |

为什么一个形状一个包装类型：CT 的映射键是（宿主, 方法名），同一宿主上 `put` 不能有两套
签名。两种形状各自成宿主，`put` / `get` / `del` 可以同名，调用点按接收者类型解析。

`namespace hashmap` 只放构造器（无接收者的能力），不放配置项。

---

## 3. 所有权与生命周期

### 3.1 表本身

- `newStrInt` / `newIntPtr` 返回的句柄由调用方唯一拥有；`release()` 释放表与全部条目。
- `release(0)` 是空操作，便于统一清理路径；非空句柄只允许 `release()` 一次。
- **没有自动析构**。包内不实现 `Drop`，原因见 §0-6。
- `clear()` 清空条目但保留当前桶数组（`hashmap_clear(map, false)`），便于复用。

### 3.2 `HashStrInt` 的键

上游 `hashmap_new(elsize, ...)` 只按 `elsize` 字节拷贝条目（`hashmap.c:34`、
`:107-112` 的 `bucketsz`、`:262` 的 `memcpy(..., elsize)`），所以"拷贝"**不等于**拷贝字符串内容。本包的规则：

- `put("abc", 1)` 时 shim 在 item 里保存 `strdup("abc")` 的结果；
- `clear()` / `release()` 由 `elfree` 回调逐条 `free`；
- **覆盖与删除不会被上游自动回收**：`hashmap_set` / `hashmap_delete` 把旧条目拷进
  `map->spare` 后返回（`hashmap.c:351-371`, `:378-380`），不调用 `elfree`。因此
  shim 在拿到非 `NULL` 返回值后立刻 `free` 旧 item 的键副本；晚一步（下一次调用覆盖
  `spare`）就泄漏。这是 S1 必须用测试钉死的点；
- 因此 `put` 返回后调用方可以立刻释放自己的键缓冲区；
- 重复键按字节比较（`strcmp`），**大小写敏感**，不做长度前缀或二进制键；
  键按 C 字符串处理，**不允许内嵌 `0x00`**（哈希与比较都按 `strlen` 截断）。

### 3.3 `HashIntPtr` 的值

- `int` 键与 `void *` 值都按值拷贝进条目；
- **值的 pointee 不被拥有、不被释放**。需要容器托管 pointee 时，由调用方在 `clear()` /
  `release()` 之前自行释放；本包不提供 `free_fn`（与 `std::map` 的 `MapIntPtr` 不同，
  这里刻意不复制那条所有权钩子，避免两个包在析构语义上分叉）。
- `void *` 值允许为 0；`get` 用状态码返回"找到/未找到"，不靠空指针判定。

### 3.4 借出的指针

`get` 的 `out` 是**拷出**值，不借出内部指针，没有悬垂问题。迭代器例外：

- `iter.key()` / `iter.value()` 指向表内部条目，**任何后续 `put` / `del` / `clear` 都会使其失效**
  （上游 README 明确"DO NOT RETAIN POINTERS RETURNED BY HASHMAP CALLS"）；
- 迭代器自身需要 `release()`；`release(0)` 空操作。

---

## 4. 对外契约

状态码（`HashMapTypes.h.ct`）：

| 常量 | 值 | 含义 |
| --- | ---: | --- |
| `HMAP_OK` | 0 | 成功 |
| `HMAP_NOT_FOUND` | 1 | 键不存在 |
| `HMAP_INVALID` | 2 | 参数非法（空键、空句柄） |

枚举值紧凑为 0 / 1 / 2，与 `dict` 的 `DICT_OK` / `DICT_NOT_FOUND` / `DICT_INVALID`
一一对应。原先留给 OOM 的编号 2 已删除并由 `HMAP_INVALID` 接续：不保留空位，也不复用旧语义；
包未发布，编号前移没有兼容负担。状态码里没有 OOM 项——内存不足直接终止进程（§6）。

### 4.1 `namespace hashmap`（`Lib`）

| 方法 | 签名 | 说明 |
| --- | --- | --- |
| `newStrInt` | `HashStrInt *newStrInt(int initialCapacity)` | 容量 0 表示上游默认；种子固定 0/0 |
| `newStrIntSeeded` | `HashStrInt *newStrIntSeeded(int initialCapacity, long long seed0, long long seed1)` | 面向不可信键，显式给种子 |
| `newIntPtr` | `HashIntPtr *newIntPtr(int initialCapacity)` | 同上 |
| `newIntPtrSeeded` | `HashIntPtr *newIntPtrSeeded(int initialCapacity, long long seed0, long long seed1)` | 同上 |

失败（分配不到表）即终止进程，不返回 0（§6）。固定种子 0/0 让测试可复现，但**对攻击者可控的键不设防**
（哈希洪泛）；面向不可信输入时必须用 `*Seeded`。

### 4.2 `HashStrInt *`

| 方法 | 签名 | 说明 |
| --- | --- | --- |
| `setLoadFactor` | `HashStrInt *setLoadFactor(double factor)` | 上游夹到 `[0.50, 0.95]`（`hashmap.c:57-64`），NaN 忽略；返回接收者 |
| `put` | `HashStrInt *put(const char *key, int value)` | 插入或覆盖；键被深拷贝；返回接收者 |
| `get` | `int get(const char *key, int *out)` | `out` 可为 0，此时只判存在性 |
| `del` | `int del(const char *key)` | 返回 `HMAP_OK` / `HMAP_NOT_FOUND` |
| `len` | `int len()` | 条目数 |
| `clear` | `HashStrInt *clear()` | 清空条目，保留桶数组；返回接收者 |
| `iter` | `HashStrIntIter *iter()` | 新建只读迭代器 |
| `release` | `void release()` | 释放表与全部键副本 |

### 4.3 `HashStrIntIter *`

| 方法 | 签名 | 说明 |
| --- | --- | --- |
| `next` | `int next()` | 1 = 有当前条目，0 = 结束 |
| `key` | `char *key()` | 借用；无当前条目或已失效时返回 0 |
| `value` | `int value()` | 当前条目的值；无当前条目时返回 0 |
| `release` | `void release()` | 释放游标 |

### 4.4 `HashIntPtr *` / `HashIntPtrIter *`

方法与 §4.2 / §4.3 一一对应，仅签名不同：

- `HashIntPtr *put(int key, void *value)`；
- `int get(int key, void **out)`；
- `int del(int key)`；
- `IntPtrIter.value()` 返回 `void *`。

---

## 5. 迭代与删除

- v1 **只读遍历**。上游 `hashmap_iter` 的游标是 `size_t` + 当前 item 指针
  （`hashmap.c:413-424`）；迭代中 `hashmap_delete` 会重排桶并使游标失效。
- 需要"遍历中删除"时，调用方先把键拷到自己的容器，结束后再逐个 `del`。这是 20 行以内的
  用户侧代码，不引入第二套迭代协议。
- 迭代器创建后、`release()` 前，表上的任何写操作都使 `key()` / `value()` 失效；文档与测试
  都要覆盖这条。
- `next()` 返回 0 后不自动 `release()`；句柄仍要显式释放。

---

## 6. 失败与 OOM 语义

**共同契约（与 `dict` 同一语义）**：容器写入路径上不存在可恢复的 OOM。

- `dict` 一侧：`dict.c` 的分配点没有 `NULL` 分支，`zmalloc` 默认 handler 打印后 `abort()`，
  没有软失败的余地（`dict/docs/design.md` §6）。
- 本包一侧：失败其实**检得出来**（`hashmap_oom()`），但链式 `put` 没有错误码通道，
  检出来也只能变成"静默丢失 + 事后查状态"。两个包统一为终止进程，调用方的写路径规则一致：
  **要么成功，要么进程已经不在**。

上游事实：

- `hashmap_set` 返回 `NULL` 有两种含义：键是新的，或分配失败；只有 `hashmap_oom()` 能区分
  （`hashmap.c:293-296` 的注释，`:394-398` 的实现）。
- `hashmap_delete` 期间的缩容失败被上游刻意忽略，不影响数据完整性（`hashmap.c:365-370`）。

本包契约：

1. **OOM = 进程终止**。shim 在每次 `put` 的 `hashmap_set` 返回后检查：
   `set` 结果为 `NULL` 且 `hashmap_oom()` 为真时，向 stderr 打印
   `hashmap: out of memory: put` 并 `abort()`。公开面不提供错误码，也不提供状态查询。
2. 构造器同理：`new*` 的表分配失败直接终止（打印 `hashmap: out of memory: new`），
   不返回 0；因此状态码里没有 OOM 项（§4）。
3. 返回值只表达逻辑失败：`HMAP_NOT_FOUND`（键不存在）、`HMAP_INVALID`（空键 / 空句柄）。
4. `get` / `del` / `len` / 迭代不分配，不会触发终止；`del` 的缩容失败由上游吞掉，不影响
   数据完整性。
5. 不做自动重试、不做扩容失败回落、不做粘性状态机：终止之后没有"状态"可言。

**为何选终止（被否决方案与代价）**：

| 方案 | 代价 | 结论 |
| --- | --- | --- |
| 粘性状态 + `clearStatus()` | `t.put(a).put(b).put(c)` 中间失败不可见，只能事后 `status()`；多两个方法、一个状态字段、每条写入一次分支 | 否决：错误被推迟且更难定位 |
| `put` 返回 `int` | 放弃链式，与 ct-pkg 的 OO 默认准则冲突（裁决 D-1）；每个调用点都要写检查 | 否决 |
| 终止进程 | 调用方无法降级；写入路径简化为"成功或进程结束" | **采用**，与 `dict` 一致 |

> **裁决 D-1（2026-11-08，已定）**：按 ct-pkg 默认的 OO / 链式准则执行——`put` / `clear` /
> `setLoadFactor` 返回接收者。`map-options.md` §4.3 / §7 的"不做链式"是 ct 仓写的规划文字，
> 与 ct-pkg 的 OO 默认准则冲突时以 ct-pkg 为准；这不是笔误。链式本身不附带错误通道，
> OOM 因此按本节终止处理。若将来要改回逐次可见的 `int` 返回值，方法表不变，只改返回类型
> 与 mapping。

---

## 7. shim 数量估算

设每种形状的公开方法数为 12（句柄 8 + 迭代器 4），`namespace` 构造器 4 个。

| 项 | `HashStrInt` | `HashIntPtr` | 新增一种形状 |
| --- | ---: | ---: | ---: |
| 包装结构 `ct_hashmap_*` | 1 | 1 | +1 |
| item 结构（键 + 值） | 1 | 1 | +1 |
| 哈希函数 | 1（SipHash + `strlen`） | 1（Murmur + `sizeof(int)`） | +1 |
| 比较函数 | 1（`strcmp`） | 1（整数相等） | +1 |
| `elfree`（释放键副本） | 1（`free`） | 0 | 形状相关 |
| 覆盖/删除后的旧键回收 | 2 处内联（`put` / `del` 各一处） | 0 | 形状相关 |
| 构造器 | 2（普通 + seeded） | 2 | +2 |
| 迭代器包装 | 1 | 1 | +1 |
| mapping 行 | 12 | 12 | +12 |

合计：**C 侧 13 个对象**（7 + 6）+ **28 行 mapping**（12×2 + 4 个构造器）+ 1 个 shim 头。
新增形状的成本是"1 个 item 结构 + 1 组 hash/compare + 1 个构造器 + 12 行 mapping"，
与已有形状数无关；没有泛型，所以这个成本无法消除。

---

## 8. 与 `std::map` / `dict` 的差异（文档第一顺位）

| 维度 | `std::map` | `hashmap`（本包） | `dict` |
| --- | --- | --- | --- |
| 容量 | `init` 定容，满即失败 | 自动增长 | 自动增长 |
| 扩容 | 无 | 一次性搬全表 | 每次操作搬一点 |
| 字符串键 | 借用指针 | **深拷贝（strdup）** | 借用指针 |
| 指针值 | 借用，可配 `free_fn` | 借用，不配 `free_fn` | 借用 |
| 删除 | 无单条删除 | `del` | `del` |
| 遍历 | v1 无 | 只读迭代器 | safe iterator，可删当前 |
| OOM | `put` 返回 -1 | **进程 abort（与 `dict` 相同）** | 进程 abort |

---

## 9. 明确不做

- 不做统一 `Map` trait / 抽象层（所有权语义与 `dict` 不同，且无泛型）。
- 不做自动析构 / `Drop`。
- 不做线程安全与内置锁；`hashmap.c` 本身明确 NOT THREAD SAFE。
- 不做 OOM 软失败或粘性状态：OOM 直接终止（§6，与 `dict` 同一契约）。
- 不做迭代中删除、不做 `hashmap_scan` 回调（CT 无闭包）。
- 不做自定义 allocator 的公开入口（上游 `hashmap_set_allocator` 是进程级全局，公开会污染
  整个进程；只在测试夹具里用）。
- 不做序列化、持久化、键排序、前缀扫描。
- 不做 `void *` 键的泛型形状；新增形状按 §7 的成本单独评估。
- 不引入上游以外的任何源码；不修改上游文件（只用 `elfree` / 回调适配）。

---

## 10. 切片与验收条件

### S1.0 · 探针（不改包外文件）

- 确认 `pub type HashStrInt = struct ct_hashmap_strint;` + `map trait ... for type HashStrInt *`
  在 ct v0.20.3 可编译（与 json 的 Q-1 同类）。
- 确认字面量/命名空间调用起步的链式可用；确认 `newStrInt(0).put(...)` 作为独立语句成立，
  作为 `printf` 实参被拒绝（记录 json Q-8 的同一限制）。
- 固定上游 commit `3735986...`，把两个文件审一遍，确认 §3.2 的 `elsize` 事实。

验收：探针源码与输出落盘；结论逐条引用 `文件:行`。

### S1.1 · `HashStrInt` 核心

- 落地 `newStrInt*` / `put` / `get` / `del` / `len` / `clear` / `release`。
- 测试：插入、覆盖、删除、清空、重复 `release(0)`；`put` 后立刻 `free` 调用方键缓冲，
  再 `get` 仍命中（证明 strdup）；`clear` 后 `len == 0` 且旧键不可查。
- **同一个键覆盖 10 万次、删除 10 万次**，泄漏门禁必须为 0 增长：上游不会为覆盖/删除调用
  `elfree`，这条用例专门钉住 §3.2 的手工回收。

验收：`tests/run.sh` 全绿，`-Wall -Wextra` 零告警；泄漏门禁用**注入变异**证明会红
（分别删掉 `elfree` 与覆盖路径上的旧键回收，门禁都必须失败）。

### S1.2 · `HashIntPtr` + seeded 构造器

- 覆盖两种形状的签名差异与指针值借用语义；seeded 构造器用不同种子得到相同的查找结果，
  但桶分布不同（以 `len` / 命中为准，不依赖桶序）。

### S1.3 · 迭代器

- 遍历顺序不做承诺；断言"恰好访问全部键一次"。
- 断言迭代中 `put` 后旧 `key()` 指针不被继续使用（只测约定，不测未定义行为）。
- 迭代中删除的推荐写法（先收集再删）写成配方并跑通。

### S1.4 · 扩容与 OOM

- 容量 0 起步，插入 10 万条，扩容后旧键全部可读。
- 用测试专用 C 夹具注入第 N 次分配失败：在子进程里执行写入，断言子进程以 `abort`
  终止，且 stderr 含 `hashmap: out of memory: put`。构造器注入失败同理，文案为
  `hashmap: out of memory: new`。没有"返回值可检查"的路径，这正是 §6 的契约。

### S1.5 · 文档与安装态

- README 9 节骨架填满；所有代码块实测后写入，输出逐字一致。
- `ct get` / `ct install` 安装态验证：`third_party/` 被完整拷贝（目录名不能是 `vendor`）。
- 取消 `index/packages.txt` 的注释，并推 `v0.1.0`（`ct.pkg` 的 `version` 已是 `0.1.0`）。

---

## 11. 风险与待验证项

| # | 风险 | 处置 |
| --- | --- | --- |
| R-1 | 上游只拷贝 `elsize` 字节，误以为键字符串也被拷贝 → 悬垂 | §3.2 + S1.1 的 free-then-get 测试 |
| R-2 | 固定种子 0/0 对不可信键不设防 | 提供 `*Seeded` 构造器，README 写明 |
| R-3 | OOM 终止进程，调用方无法降级 | §6 明示为与 `dict` 的共同契约；README §5.5 与排错表 |
| R-4 | 迭代中删除导致游标失效 | v1 明确不支持，S1.3 写在配方里 |
| R-5 | `len()` 用 `int` 承载 `size_t` | 文档写明上限 2^31-1；超出不在支持范围 |
| R-6 | `pub type` 依赖 ct 0.20.3，尚未在本包实测 | S1.0 探针；失败则退回 shim typedef + 0.20.0 |
| R-7 | `third_party` 命名与安装路径 | 已在 `ct.pkg` 按 `vendor/<name>/third_party` 书写，S1.5 验证 |
| R-8 | 覆盖 / 删除不触发 `elfree`，旧键副本泄漏 | §3.2 的手工回收 + S1.1 的 10 万次覆盖/删除门禁 |
