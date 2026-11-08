# hashmap

动态增长的哈希表包，映射 [tidwall/hashmap.c](https://github.com/tidwall/hashmap.c)（MIT）。
与 `std::map`、`dict` 并列但语义不同：**条目会被拷贝进表，容量自动增长，扩容是一次性搬全表**。

> **状态：S0（需求与骨架），尚不可编译、不可安装。**
> `ct.pkg` 已登记，`version` 是声明的首个版本 `0.1.0`，但远端还没有 `v0.1.0` tag；
> `third_party/`、`map` 块与测试在 S1 落地。
> 需求与契约以 [docs/design.md](docs/design.md) 为准。

## 1. 定位与边界

做三件事：

- 动态增长的通用哈希表，容量不需要在创建时定死；
- 条目按形状拷贝：`char *` 键由包 `strdup` 深拷贝，`int` / `void *` 值按值拷贝；
- 提供显式删除、清空与只读遍历；写入路径的 OOM 直接终止（§5.5）。

不做的事：

- **不是 `std::map` 的替代**：`std::map` 定容、`put` 路径不分配、内存可预测，这些本包都不满足；
- **不是 `dict` 的替代**：本包扩容一次性搬全表，超大表会有停顿；`dict` 是增量 rehash；
- 不统一三者的接口（所有权语义不同，且语言没有泛型）；
- 不提供自动析构；只给显式 `release()`；
- **OOM 不做软失败**：内存不足时直接终止进程，没有错误码或状态查询，与 `dict` 同一契约（§5.5）；
- 不是线程安全的，也不内置锁；
- 不支持遍历中删除。

场景判据见 [docs/design.md](docs/design.md) §1，选型总表见 `ct/docs/design/map-options.md`。

## 2. 依赖与安装

| 项 | 值 |
| --- | --- |
| 包名 / 版本 | `hashmap` / `0.1.0`（未打 tag） |
| 许可 | MIT，见 [LICENSE](LICENSE) |
| 上游 | tidwall/hashmap.c，核对基线 commit `3735986914fc1c4e6a9123b406d0970666aa4aec` |
| 编译器 | `requires = ct >= 0.20.3`（依赖 `pub type`，S1 实测确认） |
| 包依赖 | 无 |
| 链接 | `ldflags` 直接编译 `third_party/hashmap.c`，不链系统库 |

**未发布状态**：本仓库没有 `v*` tag。`index/index` 里没有本包的行；
`index/packages.txt` 中的行保持注释，因为 `refresh-index.sh` 遇到无 tag 的仓库会整体失败；
`tools/repos.txt` 里 `tag` 列写 `-`。首个 tag 推送时取消 `index/packages.txt` 的注释。

安装（S1 之后）：

```sh
ct get hashmap
ct install
```

工程 `ct.pkg` 加 `dep = hashmap@^0.1.0`。`ct install` 会把
`-I vendor/hashmap/third_party` 与 `vendor/hashmap/third_party/hashmap.c` 折进它打印的构建命令。

## 3. 快速开始

目标形态（**尚未编译，S1 落地后替换为实测文件与输出**）：

- 建表：`hashmap::Lib.newStrInt(0)`；
- 写入：`h.put("alice", 30).put("bob", 25)`；
- 读取：`h.get("alice", &age)`，返回 `HMAP_OK` / `HMAP_NOT_FOUND`；
- 遍历：`HashStrIntIter *it = h.iter()`，循环 `it.next()`，用 `it.key()` / `it.value()`；
- 收尾：`it.release()`、`h.release()`。

链式从 `namespace` 调用起步是被允许的；把整条链直接塞进 `printf` 实参会被编译器拒绝
（与 json 包记录的限制相同），先赋给变量即可。

## 4. API 全表

四个宿主，方法名互不冲突；`namespace hashmap` 只放构造器。

### 4.1 `namespace hashmap`（`Lib`）

| 方法 | 签名 | 语义 |
| --- | --- | --- |
| `newStrInt` | `HashStrInt *newStrInt(int initialCapacity)` | 建 `char *` → `int` 表；容量 0 用上游默认；分配失败即终止（§5.5） |
| `newStrIntSeeded` | `HashStrInt *newStrIntSeeded(int initialCapacity, long long seed0, long long seed1)` | 同上，显式给哈希种子 |
| `newIntPtr` | `HashIntPtr *newIntPtr(int initialCapacity)` | 建 `int` → `void *` 表 |
| `newIntPtrSeeded` | `HashIntPtr *newIntPtrSeeded(int initialCapacity, long long seed0, long long seed1)` | 同上，显式给种子 |

### 4.2 `HashStrInt *`

| 方法 | 签名 | 语义 |
| --- | --- | --- |
| `setLoadFactor` | `HashStrInt *setLoadFactor(double factor)` | 夹到 `[0.50, 0.95]`，NaN 忽略；返回接收者 |
| `put` | `HashStrInt *put(const char *key, int value)` | 插入或覆盖；键被深拷贝；返回接收者 |
| `get` | `int get(const char *key, int *out)` | `out` 可为 0，只判存在性 |
| `del` | `int del(const char *key)` | 删除并返回状态 |
| `len` | `int len()` | 条目数，上限 2^31-1 |
| `clear` | `HashStrInt *clear()` | 清空条目，保留桶数组；返回接收者 |
| `iter` | `HashStrIntIter *iter()` | 新建只读迭代器 |
| `release` | `void release()` | 释放表与全部键副本；`release(0)` 空操作 |

### 4.3 `HashStrIntIter *`

| 方法 | 签名 | 语义 |
| --- | --- | --- |
| `next` | `int next()` | 1 = 有当前条目，0 = 结束 |
| `key` | `char *key()` | 借用，下次写操作后失效 |
| `value` | `int value()` | 当前条目的值 |
| `release` | `void release()` | 释放游标 |

### 4.4 `HashIntPtr *` / `HashIntPtrIter *`

与 §4.2 / §4.3 同构，签名差异：

- `put(int key, void *value)`；
- `get(int key, void **out)`；
- `del(int key)`；
- `IntPtrIter.value()` 返回 `void *`。

### 4.5 状态码

| 常量 | 值 | 含义 |
| --- | ---: | --- |
| `HMAP_OK` | 0 | 成功 |
| `HMAP_NOT_FOUND` | 1 | 键不存在 |
| `HMAP_INVALID` | 2 | 空键 / 空句柄 |

枚举值紧凑为 0 / 1 / 2，与 `dict` 的 `DICT_OK` / `DICT_NOT_FOUND` / `DICT_INVALID`
一一对应；原先留给 OOM 的编号 2 已删除并由 `HMAP_INVALID` 接续，不保留空位。状态码里
没有 OOM 项——内存不足直接终止进程，见 §5.5。

## 5. 教程正文

### 5.1 何时选本包

容量在运行中才知道、希望 `put` 完就能释放自己的键、能接受扩容时的一次性停顿，选本包。
容量固定且禁止 `put` 分配，选 `std::map`；十万级以上且不能接受扩容停顿，选 `dict`。

### 5.2 "拷贝"到底拷了什么

- `HashStrInt`：键字符串被 `strdup` 一份，`put` 返回后可以立刻 `free` 调用方的缓冲区；
  替换、删除、清空、释放都会回收这份副本。
- `HashIntPtr`：键与值都按值拷贝，`void *` 指向的对象**不归包所有**，包不会释放它。

这是本包最容易出错的地方，也是与 `dict` 最本质的差异：`dict` 只存指针，键必须一直活着。

### 5.3 链式与返回值

配置与写入都返回接收者：`h.setLoadFactor(0.75).put(...).put(...)`。
返回值只表达"接收者本身"，不携带成功/失败信息；链式是 ct-pkg 的默认 OO 准则
（`map-options.md` 里"不做链式"是 ct 仓的规划文字，两者冲突时以 ct-pkg 为准，
见设计文档 D-1）。写入路径的失败语义只有一种：内存不足即终止，见 §5.5。

### 5.4 遍历

迭代器只读，顺序不承诺。`key()` / `value()` 指向表内部，任何 `put` / `del` / `clear` 之后
都不能再使用；迭代器本身要 `release()`。遍历中要删除，先把键拷出来，结束后再删。

### 5.5 失败语义（对外契约）

**内存不足 = 进程终止，不返回错误码。** 这是本包与 `dict` 共同的契约。

链式 `put` 返回接收者本身，没有错误码通道，软失败只能表现为"后续写入静默丢失 + 事后查
状态"，调用方写 `t.put(a).put(b).put(c)` 时无法察觉中间丢失。因此 shim 在每次
`hashmap_set` 之后检查 `hashmap_oom()`：置位就向 stderr 打印
`hashmap: out of memory: put` 并 `abort()`；构造器的表分配失败同理，文案为
`hashmap: out of memory: new`。

调用方**不需要、也不能**处理 OOM：容器写入路径上不存在可恢复的失败。
返回值只表达逻辑失败：键不存在（`HMAP_NOT_FOUND`）、参数非法（`HMAP_INVALID`）。
需要 OOM 可恢复语义时不要选本包：`std::map` 的 `put` 返回 -1；`dict` 与本包一样终止。

## 6. 常见配方

- **覆盖前想知道旧值**：先 `get`，再 `put`；本包 `put` 不返回旧值。
- **批量装载**：`newStrInt(100000)` 给足初始容量，减少扩容次数。
- **遍历中删除**：把 `key()` 拷进自己的缓冲区数组，遍历结束后逐个 `del`。
- **不可信键**：用 `newStrIntSeeded`，种子来自进程级随机源；不要用默认的 0/0。
- **指针值的清理**：在 `clear()` / `release()` 之前自行遍历释放 pointee。

## 7. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `put` 之后 `get` 不到 | 键内容被调用方改过，或比较的是字节而大小写不同 | 键按 `strcmp` 比较，区分大小写；`HashStrInt` 内部是副本，改原缓冲不影响已插入的键 |
| 进程在大量插入时退出，stderr 有 `hashmap: out of memory: put` | 内存不足，本包按共同契约终止进程 | 不是可捕获的错误；降低内存压力，或改用定容的 `std::map` |
| 遍历拿到的指针读出错值 | 迭代期间发生了写操作 | v1 不支持迭代中写；先收集再改 |
| 安装后编译报找不到 `hashmap.h` | 第三方目录被放进了 `vendor/` | 必须是 `third_party/`；`ct get` 会跳过 `vendor` |

## 8. 术语表（Glossary）

| 术语 | 含义 | 本包中的所指 |
| --- | --- | --- |
| `borrow`（借用） / 所有权（ownership） | 借用是只保存或返回指针、不取得所有权、由调用方负责释放的引用方式；所有权指"谁负责在何时释放对象"。 | `HashIntPtr` 的 `void *` 值与 `key()` 返回的 `char *` 是借用；`clear()` / `release()` 不释放 pointee。`HashStrInt` 的键不是借用——它是包 `strdup` 出来的副本。 |
| `handle`（句柄） | 指向包内部对象的不透明标识；调用方只能通过包的方法操作它，不能解引用或自行分配。 | `HashStrInt *`、`HashIntPtr *`、`HashStrIntIter *`、`HashIntPtrIter *` 四个句柄。 |
| `host`（宿主） | CT 映射表里方法挂靠的类型；方法按（宿主, 方法名）寻址，同一宿主上不能有两个同名方法。 | 上述四个类型各自是宿主；`namespace hashmap`（trait `Lib`）只挂四个构造器。 |
| `mapping`（映射） | 把 CT 方法转发到 C 实现的 shim 注册行，一个公开方法对应一行。 | S1 落地：每个形状 12 行（表 8 + 迭代器 4），四个构造器另计，估算见 `docs/design.md` §7。 |
| 链式返回自身 | 配置 / 写入方法返回接收者本身，以便把多次调用连成一条表达式；返回值不携带成功 / 失败信息。 | `setLoadFactor` / `put` / `clear` 返回 `HashStrInt *` 或 `HashIntPtr *` 本身；`get` / `del` / `len` 返回状态码或计数。链没有错误通道，这正是 OOM 只能终止的原因（§5.5）。 |
| `pub type` | CT 的公开类型别名声明；本包用它把 C 侧包装结构暴露成 CT 句柄，公开面不出现 C 类型。 | `HashMap.m.ct` 里的四个 `pub type`：`HashStrInt = struct ct_hashmap_strint`、`HashIntPtr = struct ct_hashmap_intptr`，以及对应的两个迭代器类型；`struct hashmap` 只出现在 shim。 |
| `shim` | C 侧适配层：把 CT trait 方法桥接到上游 C API 的静态内联函数与注册代码。 | `hashmap/HashMap.m.ct` 的 trait 由 shim 实现（S1 落地）；`item` 结构、`elfree`、`hashmap_oom()` 检查都在这一层。 |
| `HashStrInt` / `HashIntPtr`（两种形状） | 本包两个具体表类型，键值归属不同，各自独立成宿主。 | `HashStrInt *`：`char *` 键由包 `strdup` 深拷贝 → `int` 值按值拷贝；`HashIntPtr *`：`int` 键按值拷贝 → `void *` 值只拷贝指针、pointee 不归包所有。构造器为 `newStrInt` / `newStrIntSeeded` 与 `newIntPtr` / `newIntPtrSeeded`。 |
| 条目拷贝 / 深拷贝 | 条目拷贝指按 `elsize` 复制条目结构本身；深拷贝指连键指向的内容一起复制。 | `put` 对 `char *` 键做深拷贝（`strdup`），调用方随后可以 `free` 自己的缓冲区；`HashIntPtr` 的 `int` 键与 `void *` 值只做条目拷贝，不碰 pointee。 |
| `elsize` / `bucketsz` | 上游 `struct hashmap` 的两个尺寸字段：单个条目的字节数，以及每个桶的跨距（桶头加条目，向上对齐到指针宽度）。 | `hashmap.c:34` 声明 `elsize`，`:107-110` 由 `elsize` 算出 `bucketsz`；上游只按这两个尺寸 `memcpy`，所以"拷贝"不含键字符串内容。 |
| `elfree` / `spare` | 上游的条目回收回调，以及 `hashmap_set` / `hashmap_delete` 把旧条目拷出来返回用的临时缓冲区。 | `elfree` 只在 `clear()` / `release()` 时逐条调用；覆盖与删除不调用它——旧条目被拷进 `map->spare` 后返回（`hashmap.c:276-278`、`:351`），shim 必须在返回后立刻 `free` 旧键副本，晚一步就被下一次调用覆盖而泄漏。 |
| Robin Hood（开放寻址） | 开放寻址的一种冲突消解策略：探测距离短的条目让位给更长的，把探测长度摊平。 | 上游 `hashmap.c` 的实现基础（`struct bucket` 的 `dib` 字段、`hashmap.c:280-285` 的交换）；本包不暴露桶结构，调用方只看到自动扩容与一次性搬全表。 |
| 一次性扩容 / `rehash` | 桶数变化后把条目重新分布到新桶数组的过程；一次性指扩容瞬间搬完整表。 | 本包是一次性：`put` 触发扩容时搬全表，超大表会出现可感知停顿；`dict` 是增量 rehash。 |
| `load factor`（装载因子） | 条目数达到桶数的多少比例时触发扩容。 | `setLoadFactor(double)` 把它夹到 `[0.50, 0.95]`，NaN 忽略；默认 0.60（上游 `GROW_AT`）。 |
| 粘性状态机（sticky status） | 把最近一次失败记在表上、由调用方事后查询并清除的错误模型。 | 本包**没有**：链式 `put` 没有错误通道，OOM 直接终止进程，所以公开面没有 `status()` / `clearStatus()`，也没有状态字段。 |
| 只读迭代 | 遍历期间不允许修改表的迭代方式；删除会重排桶并使游标失效。 | `iter()` 返回 `HashStrIntIter *` / `HashIntPtrIter *`；`key()` / `value()` 是借用，任何 `put` / `del` / `clear` 之后都失效。遍历中要删除，先拷键，结束后再 `del`。 |
| `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID` | 本包三个状态码：成功、键不存在、参数非法。 | 值为 0 / 1 / 2，定义在 `HashMapTypes.h.ct`；`HMAP_INVALID` 由空键、空句柄触发，编号 2 不留给 OOM。 |
| `OOM` | out of memory，内存分配失败。 | 本包直接进程终止：`put` 之后 `hashmap_oom()` 置位就向 stderr 打印 `hashmap: out of memory: put` 并 `abort()`，构造器失败打印 `hashmap: out of memory: new`；调用方不需要、也不能处理。与 `dict` 的共同契约（§5.5）。 |
| `third_party/` / `vendor/` | 存放 vendored 上游源码的目录约定。 | 上游 `hashmap.c` / `hashmap.h` 放 `third_party/`；不能改名 `vendor/`，`ct get` 会跳过该目录。 |
| `S0` / `S1` | 本包落地切片的编号。 | S0 = 需求与骨架（当前状态），S1 = 上游核对、实现、测试与安装态验收，见 `docs/design.md` §10。 |

## 9. 限制与未支持

- **没有自动析构**：包只提供 `release()`；调用方要用 `impl Drop` 得在自己的单元里写。
- **OOM 直接终止进程**（与 `dict` 相同），没有错误码或状态可查；写入路径上不存在可恢复的 OOM（§5.5）。
- **迭代中不能删除**，也没有 `hashmap_scan` 回调（语言无闭包）。
- **迭代器借出的指针会失效**：任何写操作之后都不能再用。
- **不拥有 `void *` 指向的对象**，也不提供 `free_fn`（与 `std::map` 的 `MapIntPtr` 不同）。
- **`len()` 是 `int`**，超过 2^31-1 条不在支持范围。
- **默认种子 0/0 是确定性的**，不适合攻击者可控的键；需要时用 `*Seeded`。
- **键是 C 字符串**，按 `strlen` / `strcmp` 处理，不允许内嵌 `0x00`；不支持二进制键。
- **一次性扩容**：超大表扩容会出现可感知停顿，这是与 `dict` 的核心差异。
- **非线程安全**；并发由调用方加锁。
- **不做泛型形状**：新增键值形状需要新增 shim 与 mapping（成本见设计文档 §7）。

## 10. 版本与变更记录

### 0.1.0（2026-11-08，未发布）

- 文档：新增 §8 术语表（Glossary），原 §8 / §9 顺延为 §9 / §10。
- S0：需求与骨架。`ct.pkg`、10 节 README、契约 `.m.ct` / `.h.ct`、`tests/` 占位。
- OOM 语义统一为进程终止（与 `dict` 一致）：状态码为 `HMAP_OK` / `HMAP_NOT_FOUND` /
  `HMAP_INVALID`（0 / 1 / 2），没有 OOM 项。
- 未写实现、未拷第三方源码、未打 tag、未 push。
- 首个 tag 为 `v0.1.0`，在此之前完成设计文档 §10 的 S1.0–S1.5。
