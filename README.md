# hashmap

一个动态增长的哈希表：容量未知时也能一直写下去，键值按条目拷进表中，调用方写完即可放手。
底层是 [tidwall/hashmap.c](https://github.com/tidwall/hashmap.c)（MIT，单文件，Robin Hood 开放寻址），
本包把它包装成两种 CT 形状：`HashStrInt`（`char *` 键 → `int` 值）与 `HashIntPtr`
（`int` 键 → 借用的 `void *` 值）。

> 状态：`0.1.0`，已发布（tag `v0.1.0`）。源码、测试与门禁已完整；安装方式见 §2。

---

## 1. 定位与边界

`hashmap` 覆盖“容量在构造时定不下来、希望容器替调用方持有键”的通用业务表。

| 场景 | 选 `std::map` | 选 `hashmap` | 选 `dict` |
| --- | --- | --- | --- |
| 容量 `init` 时能定死，`put` 不许分配 | ✅ 唯一 | ❌ | ❌ |
| 规模未知，键值交给容器持有 | ❌ 会满 | ✅ 首选 | ⚠️ 需自己管键值 |
| 十万级以上、扩容不能有长停顿 | ❌ | ⚠️ 扩容是一次性搬全表 | ✅ |
| 遍历中删除 | ❌ 无遍历 | ❌ 本版不支持 | ✅ safe iterator |
| 想少一个第三方依赖 | ✅ | ✅ 单文件 | ❌ |

包内只做三件事：把两种形状的读写映射成接收者上的方法；把 `char *` 键深拷贝并负责回收；
把上游的分配失败转成进程终止。其余（业务校验、值对象的生命周期、并发）都留给调用方。

明确的边界：

- **只读迭代**。遍历过程中删除会让游标失效（上游会重排桶），本版不提供该能力，
  需要删就先收集键、结束遍历后再删（见 §6）。
- **每个形状一个宿主**。`put` / `get` / `del` 在两个形状上同名，但接收者类型不同，
  因此不会歧义；不存在的第三形状请用 `std::map` 或自己包装，包不提供泛型。
- **不做自动析构**。只提供显式 `release()`；要在自己的类型里自动释放，请在该单元的
  `impl Drop` 中调用它。
- **不暴露分配器钩子**。表不能改变同进程其他表的分配行为；OOM 只有一种结局，见 §5.8。

## 2. 依赖与安装

- 编译器：`ct >= 0.20.3`（`pub type` 类型别名）。已用 `ct v0.20.3` 实测。
- 门禁前置：`bash` + `python3`（`tools/check.sh` 的枚举镜像与 README 块比对、
  `tools/mutation.sh` 的注入与 sha 重写使用）。这只是**开发/门禁**前置；包本身与
  消费者运行时都不需要 `python3`。
- 第三方：`third_party/hashmap.c` / `hashmap.h`，固定在上游 commit
  `3735986914fc1c4e6a9123b406d0970666aa4aec`（2026-11-08 的 `master`），MIT，
  校验值见 `tools/third_party.sha256`。
- 不依赖 `std`，也不依赖其他 ct-pkg 包。

`ct.pkg` 声明：

```text
name = hashmap
version = 0.1.0
licence = MIT
cflags = -I vendor/hashmap/third_party
ldflags = vendor/hashmap/third_party/hashmap.c
requires = ct >= 0.20.3
```

`cflags` / `ldflags` 是**安装后**的相对路径：包会被装到消费者的 `vendor/hashmap/`，
消费者只需 `ct install`，不必自己拼 `-I` 与 `hashmap.c`。

包的 `v0.1.0` 已发布。索引登记由 `ct-pkg/index` 的刷新流程单独维护；索引更新前用本地路径安装：

```bash
cd your-project            # 需要有 ct.pkg 的工程根
ct get /path/to/ct-pkg/hashmap
ct install
```

安装后目录形如 `vendor/hashmap/third_party/hashmap.c`。第三方目录必须叫 `third_party/`：
`ct get` 的拷贝与摘要逻辑会静默跳过名为 `vendor/` 的目录，那样装完就少文件。

## 3. 快速开始

下面是 [demo/main.ct](demo/main.ct) 的全文，`tests/run.sh` 会编译并逐字比对输出：

```ct
import hashmap::HashMapTypes;
import hashmap::HashMap;

#include <stdio.h>

int main(void)
{
    HashStrInt *ages;
    HashStrIntIter *it;
    HashIntPtr *owners;
    int v;
    int st;
    int count;
    int sum;
    int alice;
    int bob;
    void *owner;

    alice = 1;
    bob = 2;

    /* Configure and insert in one expression: every write returns the table. */
    ages = hashmap::Lib.newStrInt(0).setLoadFactor(0.75);
    ages.put("alice", 30).put("bob", 25).put("carol", 41);

    st = ages.get("bob", &v);
    printf("bob: status=%d age=%d len=%d\n", st, v, ages.len());

    ages.put("bob", 26);
    st = ages.get("bob", &v);
    printf("bob after overwrite: status=%d age=%d len=%d\n", st, v, ages.len());

    st = ages.del("alice");
    printf("alice after del: status=%d len=%d\n", st, ages.len());

    /* Walk without depending on the order: count and sum only. */
    count = 0;
    sum = 0;
    it = ages.iter();
    while (it.next()) {
        count = count + 1;
        sum = sum + it.value();
    }
    it.release();
    printf("walk: count=%d sum=%d\n", count, sum);
    ages.release();

    /* A pointer value is copied, never owned: the pointee stays with us. */
    owners = hashmap::Lib.newIntPtr(0);
    owners.put(7, &alice).put(9, &bob);
    st = owners.get(7, &owner);
    printf("intptr: status=%d same=%d len=%d\n", st, owner == &alice, owners.len());
    owners.release();

    return 0;
}
```

实际输出（`demo/expected.out`）：

```text
bob: status=0 age=25 len=3
bob after overwrite: status=0 age=26 len=3
alice after del: status=0 len=2
walk: count=2 sum=67
intptr: status=0 same=1 len=2
```

编译与运行（未安装时直接指向包目录）：

```bash
ct build -I /path/to/ct-pkg/hashmap \
    --cflags "-I /path/to/ct-pkg/hashmap/third_party -Wall -Wextra" \
    --ldflags "/path/to/ct-pkg/hashmap/third_party/hashmap.c" \
    demo/main.ct -o demo && ./demo
```

`import hashmap::HashMap` 只带来 trait（方法宿主），状态常量在 `hashmap::HashMapTypes`；
两个都 import 才能写 `HMAP_OK` 这类名字。

## 4. API 全表

### 4.1 构造器（`hashmap::Lib`，namespace 宿主）

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `newStrInt(capacity)` | `HashStrInt *` | `char *` → `int`，固定种子 0/0 |
| `newStrIntSeeded(capacity, seed0, seed1)` | `HashStrInt *` | 同上，种子由调用方给 |
| `newIntPtr(capacity)` | `HashIntPtr *` | `int` → 借用 `void *`，固定种子 0/0 |
| `newIntPtrSeeded(capacity, seed0, seed1)` | `HashIntPtr *` | 同上，种子由调用方给 |

`capacity` 是**预期条目数**提示：`<= 0` 表示用上游默认值（16 个桶），给正数会一次分配足够的桶，
省掉早期的扩容。它不是上限，表会继续增长。

### 4.2 `HashStrInt *`（`char *` 键，容器持有键副本）

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `setLoadFactor(factor)` | `HashStrInt *` | 配置负载因子，上游钳制到 `[0.50, 0.95]`，`NaN` 忽略 |
| `put(key, value)` | `HashStrInt *` | 插入或覆盖；键被深拷贝，`NULL` 被忽略（`""` 是合法键） |
| `get(key, out)` | `int` | `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID`；`out` 可为 `NULL`（只判存在） |
| `del(key)` | `int` | `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID` |
| `len()` | `int` | 条目数，上限钳制到 `2147483647` |
| `clear()` | `HashStrInt *` | 删除全部条目并回收键副本，保留桶数组以便复用（峰值内存不还给 OS） |
| `iter()` | `HashStrIntIter *` | 新建只读游标，用完必须 `release()` |
| `release()` | `void` | 释放整张表，**之后**不得再使用该表的任何游标 |

### 4.3 `HashStrIntIter *`

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `next()` | `int` | 前进一条，`1` 表示当前有效，`0` 表示结束 |
| `key()` | `const char *` | 当前键，**借用且只读**；仅在 `next()` 返回 `1` 时有效，否则为 `0` |
| `value()` | `int` | 当前值；无效位置返回 `0` |
| `release()` | `void` | 释放游标（不释放表，也不释放键） |

### 4.4 `HashIntPtr *`（`int` 键，借用指针值）

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `setLoadFactor(factor)` | `HashIntPtr *` | 同 4.2 |
| `put(key, value)` | `HashIntPtr *` | 只拷贝指针本身；`NULL` 是合法值 |
| `get(key, out)` | `int` | `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID`；`NULL` 值仍是 `HMAP_OK` |
| `del(key)` | `int` | `HMAP_OK` / `HMAP_NOT_FOUND` / `HMAP_INVALID` |
| `len()` | `int` | 条目数 |
| `clear()` | `HashIntPtr *` | 清空条目，不触碰任何指向对象；保留桶数组 |
| `iter()` | `HashIntPtrIter *` | 新建只读游标 |
| `release()` | `void` | 释放整张表 |

### 4.5 `HashIntPtrIter *`

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `next()` | `int` | 同上 |
| `key()` | `int` | 当前键；仅在 `next()` 返回 `1` 时有效。合法键 `0` 与「未定位」都返回 `0`，二者不可区分 |
| `value()` | `void *` | 当前指针值，借用；无效位置返回 `0` |
| `release()` | `void` | 释放游标 |

### 4.6 状态码（`hashmap::HashMapTypes`）

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `HMAP_OK` | 0 | 命中，或写入成功 |
| `HMAP_NOT_FOUND` | 1 | 键不存在 |
| `HMAP_INVALID` | 2 | 参数非法：句柄为空，或 `get` / `del` 的键为 `NULL` |

键的合法性只由指针决定：`NULL` → `HMAP_INVALID`（`put` 则静默忽略并返回接收者）；
长度为 0 的合法指针（`""`）是正常键，与上游按「指针 + 长度」处理字节切片的语义一致。

状态码只描述**逻辑失败**。写入路径上的内存不足不是状态码，见 §5.8。

## 5. 教程正文

### 5.1 构造与容量提示

```ct
HashStrInt *h = hashmap::Lib.newStrInt(0);
HashStrInt *big = hashmap::Lib.newStrInt(4096);
```

（来源：`tests/docs.ct` 的 `snippet_construct`，随 `tests/run.sh` 编译运行。）

### 5.2 写入与读回

```ct
h.put("alice", 30).put("bob", 25);
int v;
int st = h.get("bob", &v);
if (h.get("alice", 0) == HMAP_OK) {
    /* 存在，继续业务 */
}
```

（来源：`tests/docs.ct` 的 `snippet_write_read`。）

`put` 返回接收者，所以连续写入是一条表达式。`get` 的 `out` 可传 `NULL` 只判存在。

### 5.3 覆盖与所有权

`put` 遇到已有键时覆盖值，条目数不变。**键总是被深拷贝**：调用方可以在 `put` 返回后立刻
释放或改写自己的缓冲区，表里的键仍是当初的字节。这一点由 [tests/copy.ct](tests/copy.ct) 断言，
包括“释放后仍能命中”和“改写缓冲区不影响已存键”。

`value` 是 `int`，没有所有权问题。`HashIntPtr` 的值只拷贝指针：指向对象归调用方，
表既不复制也不释放它。

### 5.4 删除

```ct
int st = h.del("bob");   /* HMAP_OK；再删一次得到 HMAP_NOT_FOUND */
```

（来源：`tests/docs.ct` 的 `snippet_delete`。）

删除会回收该键的副本，`len()` 随之减一。`del` 对 `NULL` 键返回 `HMAP_INVALID`。

### 5.5 清空与释放

`clear()` 删条目、留桶数组，适合“每轮复用同一个表”；`release()` 连表一起释放。
留桶数组的代价是**峰值内存不还给 OS**：表一旦长到 N 个桶，`clear()` 之后仍然占着，直到 `release()`。

```ct
HashStrInt *h = hashmap::Lib.newStrInt(0).put("old", 1);
h.clear().put("carol", 41);
h.release();
```

（来源：`tests/docs.ct` 的 `snippet_clear_release`。）

### 5.6 遍历

顺序**不作承诺**。唯一合法的用法是只读遍历，或者先收集再删：

```ct
int count = 0;
HashStrIntIter *it = h.iter();
while (it.next()) {
    count = count + 1;
}
it.release();
```

（来源：`tests/docs.ct` 的 `snippet_iterate`。`it.key()` 是借用指针，只在当前条目有效。）

需要“边遍历边删”时，先收集键，结束遍历后再删；完整配方见 §6.1。

### 5.7 两种形状怎么选

- 键是字符串、值是整数 → `HashStrInt`，容器持有键副本，最省心。
- 键是整数、值是对象指针 → `HashIntPtr`，容器只记地址，对象生命周期仍归调用方。
- 值是浮点、结构体或第二层容器 → 用 `std::map`，或把值压缩成指针用 `HashIntPtr`。

### 5.8 内存不足：进程终止

写入路径没有错误码通道。`put` 返回接收者，如果扩容失败却“软失败”，链式调用中间那次写入
就会静默丢失，调用方无从察觉。因此本包的契约是：

- 构造器（包装或上游表）分配失败 → stderr 打印 `hashmap: out of memory: new` 并 `abort()`；
- 写入路径（键副本、扩容）分配失败 → stderr 打印 `hashmap: out of memory: put` 并 `abort()`；
- 迭代器包装分配失败 → stderr 打印 `hashmap: out of memory: iter` 并 `abort()`。

固定前缀 `hashmap: out of memory: ` 是契约；其后的 `new` / `put` / `iter` 只是**诊断信息**，
用于定位现场，调用方不应解析。三个站点都是显式 `abort()`，包内没有
「返回 `NULL` / `0` 让调用方猜」的静默失败路径。因此 `put` 只有两种结果：成功，
或进程已经结束。调用方不需要、也无法处理 OOM。
这是与 `dict` 一致的契约；软失败方案留给后续独立切片，不在本版。

`tests/oom.sh` 用测试专用夹具在子进程里注入第 N 次分配失败（上游分配器与 shim 自己的
三处 `malloc` 都覆盖），断言退出状态是 `SIGABRT`（`134`）且 stderr 以
`hashmap: out of memory: ` 开头，并附带一个“不注入时必须正常结束”的阴性对照，
防止“程序永远 abort”蒙混过关。

### 5.9 链式返回的编译边界

所有配置与写入方法都返回接收者：

```ct
h.setLoadFactor(0.75).put("a", 1).put("b", 2);
```

但“把整条链当作另一个调用的实参”有编译器限制，边界与直觉不同（ct v0.20.3 实测）：
以 namespace 构造器开头的链写在实参里也合法；以**自己写的 CT 函数**开头的链会触发
`a method call on a temporary is only allowed at the start of a statement or of an assignment`，
改写方式是先绑定：`h = make(); h.put("a", 1);`。

这条失败路径由 [tests/compile_fail/temp_receiver.ct](tests/compile_fail/temp_receiver.ct)
和 `tests/run.sh` 固定住，不靠记忆。

## 6. 常见配方

### 6.1 遍历中删除：先收集，再删

来源：`tests/docs.ct` 的 `recipe_collect_then_delete`，行为另由 [tests/iter.ct](tests/iter.ct)
以 137 条键做端到端断言。

```ct
char collected[160][32];
int count = 0;
int i;
HashStrIntIter *it = h.iter();
while (it.next()) {
    strcpy(collected[count], it.key());
    count = count + 1;
}
it.release();

for (i = 0; i < count; i = i + 1) {
    h.del(collected[i]);
}
```

键必须先复制走：游标的 `key()` 是借用，下一次 `next()` 后就可能失效。

### 6.2 计数器 / 多重集

```ct
int old;
if (h.get(w, &old) == HMAP_OK) {
    h.put(w, old + 1);
} else {
    h.put(w, 1);
}
```

（来源：`tests/docs.ct` 的 `recipe_increment`。）

### 6.3 每轮请求复用一张表

```ct
h.clear().put("q", 1).put("r", 2);
```

（来源：`tests/docs.ct` 的 `recipe_reuse`。）

`clear()` 保留桶数组，条目多的场景能省掉反复分配与释放；代价是峰值内存不还给 OS。

### 6.4 对不可信输入使用 seeded 构造器

键由外部输入决定时，固定种子可能被构造出哈希碰撞。用 `newStrIntSeeded` /
`newIntPtrSeeded` 传入进程级随机种子：

```ct
HashStrInt *h = hashmap::Lib.newStrIntSeeded(0, 123, 456);
```

（来源：`tests/docs.ct` 的 `recipe_seeded`；这里的 `123` / `456` 只是可复现的示例，
生产环境请换成进程启动时生成的随机种子。）

### 6.5 用整数键索引对象池

先用 `by_id.put(id, object)` 建索引（只记地址），取回时：

```ct
void *found;
if (by_id.get(id, &found) == HMAP_OK) {
    return found;
}
return 0;
```

（来源：`tests/docs.ct` 的 `recipe_lookup`。指向对象归调用方，表既不复制也不释放。）

## 7. 术语表（Glossary）

| 术语 | 含义 | 本包中的所指 |
| --- | --- | --- |
| 条目（item） | 表中一条“键 + 值”的记录 | 上游按固定大小 `elsize` 拷贝的结构体 |
| 深拷贝 | 连同键指向的字节一起复制 | `HashStrInt` 的 `char *` 键在 `put` 时被复制成独立缓冲区 |
| 借用（borrow） | 只拿指针，不接管释放责任 | 迭代器的 `key()`（`const char *`，只读，仅在 `next()` 返回 `1` 时有效）；`HashIntPtr` 的 `void *` 值 |
| 覆盖（overwrite） | 键已存在时替换值 | `put` 的既有键路径，条目数不变 |
| `spare` | 上游复用的一块临时条目缓冲 | 覆盖与删除时旧条目从此处返回，shim 随后释放旧键副本 |
| 负载因子（load factor） | 条目数 / 桶数 | `setLoadFactor` 设置，上游钳制到 `[0.50, 0.95]` |
| 一次性扩容 | 扩容时把整表重新分配到新桶数组 | 本包唯一的扩容形态，与 `dict` 的增量 rehash 相反 |
| 游标（cursor） | `hashmap_iter` 的位置状态 | `iter()` 返回的 `HashStrIntIter *` / `HashIntPtrIter *` |
| 宿主（host） | 方法挂靠的接收者类型 | `HashStrInt *`、`HashIntPtr *`、两个迭代器类型，以及 namespace `hashmap` |
| 链式返回 | 配置/写入方法返回接收者自身 | `setLoadFactor` / `put` / `clear` 返回同一个句柄 |
| 种子（seed） | 哈希函数的两个 64 位参数 | `newStrIntSeeded` / `newIntPtrSeeded` 的 `seed0` / `seed1` |
| OOM | 内存分配失败 | 进程终止，不返回错误码 |

## 8. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 刚 `put` 过的键 `get` 却 `HMAP_NOT_FOUND` | 键里有 `0x00`，或两端缓冲区字节不同 | 键按 C 字符串比较，遇到第一个 `0x00` 即截止；改用无 `0x00` 的键 |
| 覆盖后 `len()` 变大 | 以为是同一个键，其实字节不同（大小写、尾随空格） | 用 `strcmp` 的语义核对键 |
| `del` 返回 `HMAP_NOT_FOUND` | 键已被删过，或从未插入 | 正常语义；不要把它当错误重试 |
| 遍历时删除后行为异常 | 删除会重排桶，游标失效 | 先收集键，结束遍历后再删（§6.1） |
| 程序以 `134` 退出，stderr 有 `hashmap: out of memory` | 分配失败，按契约终止 | 调低并发/批量，或给更准确的容量提示；不要试图捕获 |
| 编译报 `method call on a temporary` | 链的根是自己写的 CT 函数，且整条链写在实参里 | 先绑定到变量再链（§5.9） |
| 编译报 `HMAP_OK` 未声明 | 只 import 了 `hashmap::HashMap` | 同时 `import hashmap::HashMapTypes` |
| 装了包却找不到 `hashmap.h` | 第三方目录被命名为 `vendor/` 或安装路径不对 | 确认 `vendor/hashmap/third_party/hashmap.h` 存在 |
| `len()` 返回 `2147483647` | 条目数超过 `int` 上限 | 本包不支持超过 2^31-1 条；拆表 |

## 9. 限制与未支持

- **不支持遍历中删除**，也不提供反向游标；先收集再删。
- **`len()` 是 `int`**，超过 `2147483647` 时钳制到该值，属于未支持区间。
- **键是 NUL 结尾的 C 字符串**，含 `0x00` 的键会被截断，不支持二进制键。
- **OOM 直接终止**，没有可恢复路径；也不提供自定义分配器入口。
- **不提供自动析构**：手工 `release()`，或在调用方单元里用 `impl Drop` 包装。
- **扩容是一次性重排**：超大表扩容会有一次可感知的停顿，延迟敏感场景请用 `dict`。
- **只有两种值形状**（`int`、`void *`），没有浮点或结构体值；需要时自行编码或换 `std::map`。
- **负载因子被上游钳制在 `[0.50, 0.95]`**，`NaN` 被忽略；超出范围不会报错。
- **`clear()` 不缩容**：桶数组保留到 `release()` 为止，峰值内存不还给 OS；需要把内存交还时请重建表。
- **没有并发保护**：一张表只能被一个线程同时使用。
- **上游固定在某个 commit**：升级需要重新生成 `tools/third_party.sha256` 并重跑全部门禁。

## 10. 版本与变更记录

- `0.1.0`（首个发布版本，tag `v0.1.0`）：两种形状与 8 个方法落地；OOM 语义为进程终止；
  `third_party/hashmap.c` 固定到 commit `3735986`；包含 `tests/run.sh`、`tests/oom.sh`、
  `tests/mem.sh`、`tools/check.sh`、`tools/mutation.sh`。

变更记录自 `v0.1.0` 起逐版本列出；当前只有初始实现，没有兼容性包袱。
