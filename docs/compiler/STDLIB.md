# RGC 标准库规范

> 状态：设计稿 v0.7（随 Phase 8 实现迭代更新）
> 定位：RGC 开箱即用功能（内建 + 标准库模块）的 **API 契约**，并参考 Python / Rust 规划远期生态。
> 状态标记：✅ 已实现 ｜ 🚧 设计中（Phase 8） ｜ ⏳ 规划中（Phase 10+，依赖 FFI/生态）

---

## 1. 定位与读者

本文档描述 RGC 语言自带的标准功能：

- **内建核心**：编译器直接支持的语义（基础类型、内建函数），无需 `import`。
- **标准库模块**（Phase 8）：随语言分发、通过 `import` 引入的模块。
- **远期模块**（Phase 10+）：参考 Python/Rust 规划的模块方向（UDP/TLS、FFI 生态、事件循环等），标注依赖与 API 草案。
- **模块系统**：`import` / `public` 的语法与解析规则。

读者：RGC 使用者（API 语义）+ 编译器实现者（契约）+ 路线图规划者。

---

## 2. 通用约定

### 2.1 命名风格

- 类型：`PascalCase`（`List`、`Maybe`、`Result`）
- 函数/方法：`snake_case`（`read_file`、`push`）
- 模块：小写（`core`、`io`、`math`）

### 2.2 可变性

- 变量默认可变（Python 风格）。
- 标准库容器（如 `List`）按 move 语义传递，借用用 `@` / `@var`。

### 2.3 错误处理

- **可恢复错误**返回 `Result[T, Err]`，不抛异常、不 abort。
- **程序员错误**（如越界索引）目前设计为**直接 abort + 诊断信息**（🚧 待定：未来可改为 `Result`）。
- 所有可能失败的 API 必须在签名中体现 `Result`，禁止静默失败。

### 2.4 所有权与借用

- 接受容器参数时，只读用 `x: @List[T]`，需要修改用 `x: @var List[T]`，转移所有权用 `x: List[T]`。
- 方法调用 `list.push(...)` 视为可变借用；`list.len()` 视为只读借用。

---

## 3. 模块总览

| 模块/分类 | 内容 | 状态 |
|-----------|------|------|
| 内建核心 | `int` / `float` / `bool` / `str` / `None` | ✅ |
| 内建函数 | `print`、`range` | ✅ |
| `core` | `to_string` | ✅ |
| `List` | 动态数组（`len`/`push`/`pop`/`get`/`set`/`insert`/`remove`/`remove_at`/`index_of`/`reverse`/`contains`/`clear`/迭代） | ✅ |
| `Map` | 键值容器（`len`/`contains`/`get`/`put`/`remove`/`keys`/`values`，开放寻址哈希表） | ✅ |
| `str` 方法 | `len`/`+`/`contains`/`startswith`/`endswith`/`char_at`/`slice`/`split`/`join`/`find`/`rfind`/`trim`/`trim_start`/`trim_end`/`replace`/`repeat`/`lines`/`to_int`/`to_float` | ✅ |
| `Maybe` | 可选值（Option） | ✅（方法已内建） |
| `Result` | 可恢复错误 | ✅（方法已内建） |
| `io` | 文件读写、追加、存在性、删除 | ✅ |
| `math` | `abs`/`min`/`max`/`sqrt`/`pow`/`floor`/`ceil` | ✅ |
| `time` | 单调时钟 / 系统时间 / 休眠 | ✅ |
| `random` | 伪随机（xorshift64 + seed） | ✅ |
| `json` | 序列化 / 反序列化（源码模块 `lib/json.rg`） | ✅ |
| `os` | 系统 / 进程 / 环境变量 / 当前目录 | ✅ |
| `args` | 命令行参数 | ✅（`args()` 已内建） |
| `regex` | 正则表达式（源码模块 `lib/regex.rg`） | ✅ |
| `bytes` | 二进制缓冲区 `Bytes` + 二进制安全文件读写（`read_bytes` / `write_bytes`，源码模块 `lib/bytes.rg`） | ✅ |
| `tar` | tar 归档读写（ustar / GNU LongLink / PAX；`list_entries` / `extract` / `create` / `builder`，源码模块 `lib/tar.rg`） | ✅ |
| **密码学** | SHA-256/384/512、HMAC、HKDF、AES-128/256-GCM、ChaCha20-Poly1305、X25519、P-256/P-384 ECDH/ECDSA、RSA PKCS#1 v1.5/PSS、大整数/Montgomery（`lib/sha2.rg` / `lib/hmac.rg` / `lib/hkdf.rg` / `lib/aes.rg` / `lib/chacha20poly1305.rg` / `lib/x25519.rg` / `lib/p256.rg` / `lib/rsa.rg` / `lib/bigint.rg`） | ✅（见 §6.17） |
| **ASN.1/X.509** | DER TLV/OID、Base64/PEM、证书解析与链校验、系统 CA 包、公钥/签名（`lib/asn1.rg` / `lib/pkey.rg` / `lib/x509.rg`） | ✅（见 §6.18） |
| 格式化 | `format(fmt, args...)`（`{}` 占位） | ✅ |
| **异步** | `async def` / `await` / `asyncio.run` / `asyncio.gather` / `asyncio.wait_any` / `Task.done` / `Task.wait` / `Task.cancel`（一任务一线程）；`event` poll 事件循环 | ✅（见 §10） |
| **网络** | TCP / UDP / HTTP/1.1 / HTTP/2 / HTTPS / gzip（源码模块 `lib/net.rg` / `lib/udp.rg` / `lib/http.rg` / `lib/http2.rg` / `lib/https.rg` / `lib/tls.rg` / `lib/gzip.rg`） | ✅（见 §11） |
| **异步网络** | `net_async`：poll 就绪等待 + 非阻塞 TCP/UDP，支持 `await`、总超时与取消传播（`lib/net_async.rg`） | ✅（见 §11.8） |

---

## 4. 内建核心类型

### 4.1 `int`

- 有符号 64 位整数（LLVM `i64`）。
- 运算：`+ - * / // % **`、比较、`-x` 一元负号、位运算 `& | ^ << >>`。
- ✅ 已实现。

### 4.2 `float`

- 双精度浮点（LLVM `double`）。
- 与 `int` 混用时自动提升为 `float`。
- ✅ 已实现。

### 4.3 `bool`

- 取值 `True` / `False`。
- ✅ 已实现。

### 4.4 `str`

- 字符串字面量：`"..."`。
- 当前能力：`print` 输出、与 `str` 字面量比较。
- 计划方法：见 §6.2。

### 4.5 `None`

- 无值类型，对应 Python `None`。
- ✅ 已实现。

---

## 5. 内建函数

> 内建函数由编译器直接识别，无需 `import`。

### 5.1 `print`

```
print(*args) -> None
```

- Python 风格多参数输出，参数之间以空格分隔，末尾换行。
- 支持 `int` / `float` / `bool` / `str`。
- ✅ 已实现。

示例：

```python
print("fib(10) =", 55)   # 输出: fib(10) = 55
```

### 5.2 `range`

```
range(n) -> iterable[int]
range(start, end) -> iterable[int]
range(start, end, step) -> iterable[int]
```

- ✅ 已实现（1–3 个参数）。目前**只能作为 `for` 循环的可迭代对象**使用。
- 单参数：`0` 到 `n-1`；双参数：`start` 到 `end-1`；三参数按 `step` 步进。
- 结束值**不包含**在迭代范围内；仅支持 `int` 参数。
- `step` 为负时递减计数（`start > end` 才有迭代）；`step` 为 `0` 时循环体一次也不执行（不会死循环）。
- 三个边界表达式均在进入循环前**各求值一次**。

示例：

```python
for i in range(5) {
    print(i)     # 0 1 2 3 4
}
for i in range(2, 6) {
    print(i)     # 2 3 4 5
}
for i in range(10, 0, -2) {
    print(i)     # 10 8 6 4 2
}
```

---

## 6. 标准库模块 API

> 以下为 Phase 8 标准库模块的 API 契约：已落地项标记 ✅，仍设计/规划中的项分别标记 🚧 / ⏳，实现前可评审调整。

### 6.1 `List[T]`

可变动态数组，连续内存，按索引访问。**编译器内建容器**：`data`/`len`/`cap` 字段不对外可见。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 构造 | `List[T]()` | 创建空列表 | ✅ |
| 长度 | `len(self) -> int` | 元素个数 | ✅ |
| 追加 | `push(self, value: T)` | 末尾追加（容量不足自动扩容） | ✅ |
| 弹出 | `pop(self) -> T` | 移除并返回末尾元素；空列表行为未定义 | ✅ |
| 索引读 | `get(self, i: int) -> T` | 越界行为未定义 | ✅ |
| 索引写 | `set(self, i: int, value: T)` | 越界行为未定义 | ✅ |
| 包含 | `contains(self, value: T) -> bool` | `int`/`float`/`bool`/`str` 可用；自定义类型暂不支持 | ✅（部分） |
| 查找 | `index_of(self, value: T) -> int` | 首个匹配下标，不存在返回 `-1`；自定义类型暂不支持 | ✅（部分） |
| 插入 | `insert(self, i: int, value: T)` | 下标钳制到 `[0, len]`，后续元素右移 | ✅ |
| 删除下标 | `remove_at(self, i: int) -> T` | 下标钳制到 `[0, len-1]`；空表返回零值 | ✅ |
| 按值删除 | `remove(self, value: T) -> bool` | 删除首个匹配元素；未找到返回 `False` | ✅（部分） |
| 反转 | `reverse(self)` | 原地反转 | ✅ |
| 清空 | `clear(self)` | 移除全部元素（保留已分配容量） | ✅ |
| 迭代 | `for x in list { ... }` | 只读迭代 | ✅ |

> **已知限制**：`List` 的堆缓冲区（`data`）与运行时拼接/转换产生的字符串目前**不自动释放**（编译器尚无析构/GC）。进程生命周期内可用，长驻内存程序后续需引入 drop/析构支持。

示例：

```python
def main() {
    xs = List[int]()
    xs.push(1)
    xs.push(2)
    print("len =", xs.len())     # len = 2
    for x in xs {
        print(x)                 # 1 2
    }
    last = xs.pop()
    print(last)                  # 2
}
```

### 6.2 `str` 方法

字符串为不可变序列。运行时拼接/转换产生的字符串为堆分配（暂不自动释放）。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 长度 | `len(self) -> int` | 字节数 | ✅ |
| 拼接 | `s1 + s2 -> str` | 字符串连接 | ✅ |
| 包含 | `contains(self, sub: str) -> bool` | 子串判断 | ✅ |
| 前缀 | `startswith(self, prefix: str) -> bool` | — | ✅ |
| 后缀 | `endswith(self, suffix: str) -> bool` | — | ✅ |
| 字符访问 | `char_at(self, i: int) -> int` | 第 `i` 字节的整数值（0-255），越界未定义 | ✅ |
| 子串 | `slice(self, start: int, end: int) -> str` | `s[start .. end)`（字节索引） | ✅ |
| 分割 | `split(self, sep: str) -> List[str]` | 按分隔符分割（省略尾空段） | ✅ |
| 分行 | `lines(self) -> List[str]` | 按 `\n` 分行，去掉每行末尾一个 `\r`，省略末尾空段 | ✅ |
| 连接 | `join(self, parts: List[str]) -> str` | 用 self 连接列表 | ✅ |
| 查找 | `find(self, sub: str) -> int` | 首次出现的字节下标，不存在返回 `-1`；空子串返回 `0` | ✅ |
| 反向查找 | `rfind(self, sub: str) -> int` | 最后一次出现的字节下标，不存在返回 `-1`；空子串返回 `len` | ✅ |
| 去空白 | `trim(self) -> str` | 去掉两端 ASCII 空白（空格、`\t`、`\n`、`\v`、`\f`、`\r`） | ✅ |
| 去左空白 | `trim_start(self) -> str` | 去掉开头 ASCII 空白 | ✅ |
| 去右空白 | `trim_end(self) -> str` | 去掉末尾 ASCII 空白 | ✅ |
| 替换 | `replace(self, old: str, new: str) -> str` | 替换全部不重叠出现；`old` 为空时原样返回 | ✅ |
| 重复 | `repeat(self, n: int) -> str` | 重复 `n` 次；`n <= 0` 返回空串 | ✅ |
| 转整数 | `to_int(self) -> Result[int, str]` | 解析失败返回 Err | ✅ |
| 转浮点 | `to_float(self) -> Result[float, str]` | 解析失败或存在尾随字符返回 Err | ✅ |

### 6.3 `Map[K, V]`

可变键值容器，**编译器内建**。键支持 `int`/`float`/`bool`/`str`；值支持任意标量/`str`。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 构造 | `Map[K, V]()` | 创建空映射 | ✅ |
| 长度 | `len(self) -> int` | 键值对数量（O(1)） | ✅ |
| 包含 | `contains(self, key: K) -> bool` | 键是否存在（平均 O(1)） | ✅ |
| 读取 | `get(self, key: K) -> V` | 键对应值；不存在返回零值/空串 | ✅ |
| 写入 | `put(self, key: K, value: V)` | 插入或更新（平均 O(1)，负载因子 0.75 时扩容） | ✅ |
| 删除 | `remove(self, key: K) -> bool` | 删除键；存在返回 `True` | ✅ |
| 键列表 | `keys(self) -> List[K]` | 全部键的快照，顺序未定义 | ✅ |
| 值列表 | `values(self) -> List[V]` | 全部值的快照，顺序未定义 | ✅ |

> **设计说明**：开放式寻址哈希表（线性探测，容量为 2 的幂）。内部保留两个 `List` 存放键/值，桶数组只存 `keys/vals` 下标（`0` 空、`-1` 墓碑、`N>0` 表示下标 `N-1`）；
> 删除只写墓碑，查找/插入按负载因子扩容重哈希。字符串键用 FNV-1a，数值键用 splitmix64 混合。
> `keys()`/`values()` 返回哈希桶顺序，**不保证插入顺序**；自定义类型键/值暂不支持。

示例：

```python
def main() {
    sym = Map[str, int]()
    sym.put("a", 1)
    sym.put("b", 2)
    print(sym.get("a"))          # 1
    print(sym.contains("z"))     # False
}
```

### 6.4 `Maybe[T]`

可选值类型，对应 Rust `Option`。用于「可能没有值」的场景。`Maybe` 为**编译器内建泛型枚举**（无需 `import`），方法由后端实现（与 `List` 一致）。

```python
enum Maybe[T] {
    Some(T)
    Nothing
}
```

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 构造 | `Maybe[T].Some(v)` / `Maybe[T].Nothing()` | 显式构造（避免歧义） | ✅（编译器已支持） |
| 判断 | `is_some(self) -> bool` / `is_nothing(self) -> bool` | — | ✅（内建） |
| 取值 | `unwrap(self) -> T` | `Nothing` 时 abort 并打印 `panic:` 消息后 `exit(1)` | ✅（内建） |
| 映射 | `map(self, f: def(T) -> U) -> Maybe[U]` | 需要函数值/闭包支持，推迟 | ⏳ |

> 模式匹配是推荐用法（编译器已支持）：

```python
match m {
    case Some(v) => print("value =", v)
    case Nothing => print("nothing")
}
```

### 6.5 `Result[T, E]`

可恢复错误类型。用于文件 IO、解析、网络等可能失败的场景。`Result` 为**编译器内建泛型枚举**（无需 `import`），方法由后端实现。

```python
enum Result[T, E] {
    Ok(T)
    Err(E)
}
```

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 构造 | `Result[T, E].Ok(v)` / `Result[T, E].Err(e)` | — | ✅（编译器已支持枚举） |
| 判断 | `is_ok(self) -> bool` / `is_err(self) -> bool` | — | ✅（内建） |
| 取值 | `unwrap(self) -> T` | `Err` 时 abort 并打印 `panic:` 消息后 `exit(1)` | ✅（内建） |
| 带错误取值 | `expect(self, msg: str) -> T` | `Err` 时 abort 并打印 `msg` | ✅（内建） |
| 错误传播 | `expr?` | `Err` 时提前返回同错误类型的 `Result` | ✅（语言级） |

**`?` 运算符**（后缀，语言级实现）：

- 操作数必须是 `Result[T, E]`；所在函数必须返回 `Result[U, E]`，错误类型 `E` 必须一致（否则编译期报错）。
- `Ok(v)` 时表达式结果为载荷 `v`，继续执行；`Err(e)` 时立即从当前函数返回 `Err(e)`。
- 成功载荷 `T` 支持 `int` / `float` / `bool` / `str` / `None`；自定义类型载荷暂不支持（枚举载荷位为单个 `i64`，后续扩展）。
- 可与成员访问/调用链组合：`read_config()?.len()`。

```python
def parse_double(s: str) -> Result[int, str] {
    n = s.to_int()?
    return Result[int, str].Ok(n * 2)
}
```

> 详细用例见 `tests/stdlib/try_operator/`。

### 6.6 `core` 类型转换

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 转字符串 | `to_string(x) -> str` | `int` / `float` / `bool` 转字符串 | ✅ |
| 码点转字符 | `chr(cp: int) -> str` | Unicode 码点 → UTF-8 字符串；负数、`> 0x10FFFF`、代理区（`0xD800–0xDFFF`）panic；`chr(0)` 产生空串（字符串以 NUL 结尾） | ✅ |
| 格式化 | `format(fmt, args...) -> str` | 字面量格式串 + `{}` 占位（见 §7） | ✅ |
| 整数转浮点 | 自动提升 | 已支持 | ✅ |

### 6.7 `io` 文件 IO（✅ 基础已内建）

`import io` 为**内建模块**（无源文件，编译器直接提供函数）。`read_file`/`write_file`/`append_file`/`exists`/`remove_file` 通过 libc 实现；除 `exists` 外均返回 `Result`。

> `io` 按 C 字符串语义处理文件内容（内容以 NUL 结尾，读写以 `strlen` 计量）；压缩包、归档、图片等二进制数据会被 NUL 截断，必须改用 `bytes.read_bytes` / `bytes.write_bytes`（§6.15）。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 读文件 | `read_file(path: str) -> Result[str, str]` | 整个文件读入字符串；失败返回 Err | ✅（内建） |
| 写文件 | `write_file(path: str, data: str) -> Result[None, str]` | 覆盖写入 | ✅（内建） |
| 追加 | `append_file(path: str, data: str) -> Result[None, str]` | 追加写入 | ✅（内建） |
| 存在 | `exists(path: str) -> bool` | 文件是否存在 | ✅（内建） |
| 删除 | `remove_file(path: str) -> Result[None, str]` | 删除失败（如文件不存在）返回 Err | ✅（内建） |

### 6.8 `math` 数学函数（✅ 已内建）

`math` 是**内建虚拟模块**（无需源文件，`import math` 即可）；同时支持省略模块前缀直接调用（用户同名函数优先）。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 绝对值 | `abs(x) -> int/float` | 结果类型跟随参数 | ✅ |
| 最值 | `min(a, b)` / `max(a, b)` | 任一参数为 float 时按 float 提升 | ✅ |
| 平方根 | `sqrt(x) -> float` | LLVM `llvm.sqrt.f64`；int 自动提升 | ✅ |
| 幂 | `pow(x, y) -> float` | LLVM `llvm.pow.f64`；int 自动提升 | ✅ |
| 取整 | `floor(x) -> float` / `ceil(x) -> float` | LLVM `llvm.floor/ceil.f64` | ✅ |

> 实现无运行时库依赖：int 分支用比较 + `select`，float 分支用 LLVM intrinsic，全部内联展开。
> Python 参考：`math` 模块；Rust 参考：`f64::sqrt` / `f64::powf`。

### 6.9 `time` 时间（✅ 已内建）

`time` 是**内建虚拟模块**，通过 `time.*` 调用，底层直接生成 libc 调用。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 单调时钟 | `time.now_monotonic() -> float` | `clock_gettime(CLOCK_MONOTONIC)`，秒，适合计时 | ✅ |
| 单调毫秒 | `time.monotonic_ms() -> int` | `CLOCK_MONOTONIC` 毫秒；Windows 走 `QueryPerformanceCounter`，`event` 定时器使用 | ✅ |
| 系统时间 | `time.now() -> int` | Unix 时间戳（秒），`time(NULL)` | ✅ |
| 休眠 | `time.sleep(seconds: float)` | `nanosleep`；负数按 0 处理 | ✅ |

### 6.10 `random` 随机数（✅ 已内建）

`random` 是**内建虚拟模块**。编译器生成进程内全局 xorshift64 状态（默认种子固定），不依赖熵源。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 种子 | `random.seed(x: int)` | 设置状态（强制非零），相同种子产生相同序列 | ✅ |
| 整数 | `random.random_int(min: int, max: int) -> int` | 闭区间 `[min, max]`；`min > max` 时退化为恒返回 `min` | ✅ |
| 浮点 | `random.random_float() -> float` | `[0, 1)`，53 位精度 | ✅ |

> **注意**：这是确定性伪随机，不用于密码学场景；未调用 `seed` 时序列在每次进程启动时相同。

### 6.11 `json` 序列化（✅ 源码模块）

> Python 参考：`json`；Rust 参考：`serde_json`。

`json` 是 **RGC 源码模块**（`lib/json.rg`），`import json` 引入。`JsonValue` 用类 + `List` 递归表示（语言不允许类按值包含自身）；解析结果用 `JsonParse { ok, error, value }` 承载，因为枚举载荷暂不支持自定义类型。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 解析 | `parse(text: str) -> JsonParse` | 成功时 `ok=True`；失败时 `error` 为原因 | ✅ |
| 序列化 | `stringify(v: @JsonValue) -> str` | 生成紧凑 JSON | ✅ |
| 构造 | `null()` / `bool_value(b)` / `int_value(n)` / `float_value(x)` / `str_value(s)` / `array()` / `object()` | 新建值 | ✅ |
| 读取 | `kind` / `is_null` / `as_bool` / `as_int` / `as_float` / `as_str` | 按 `kind` 取载荷 | ✅ |
| 容器 | `len` / `at` / `key_at` / `val_at` / `has_key` / `get` | 数组与对象访问 | ✅ |
| 修改 | `push(v: @var JsonValue, item)` / `set(v: @var JsonValue, key, item)` | 追加数组元素、新增/覆盖对象键 | ✅ |
| 修改 | `set_at(v: @var JsonValue, i, item)` / `remove_at(v: @var JsonValue, i) -> bool` / `remove(v: @var JsonValue, key) -> bool` | 覆盖/删除数组元素、删除对象键；越界或键不存在返回 `False` | ✅ |

- `kind`：`0` null、`1` bool、`2` int、`3` float、`4` str、`5` array、`6` object。
- 数字按标准 JSON 语法校验（拒绝 `-`、`1.`、`1e`、`01` 等）；int / float 区分由小数点与指数决定；整数须落在 i64 范围内，否则返回 `integer out of range`。
- 字符串转义支持 `\"` / `\\` / `\/` / `\b` / `\f` / `\n` / `\r` / `\t` / `\uXXXX`；`\u` 支持 UTF-16 代理对（如 `\ud83d\ude00` → 😀）。
- 解析拒绝：未知转义（`unsupported escape`）、孤立代理项或非法 `\u`（`invalid unicode escape`）、原始未转义控制字符（`unescaped control character`）、`\u0000`（`NUL character not supported`，RGC 字符串以 NUL 结尾）。
- 嵌套深度上限 256 层，超出返回 `nesting too deep`。
- `stringify` 输出合法 JSON：控制字符写成 `\b` / `\f` / `\n` / `\r` / `\t` 或 `\u00XX`；非有限浮点（`inf` / `nan`）写成 `null`；解析得到的数字保留原始文本（如 `1e999` 原样输出）。
- 对象保留插入顺序，不拒绝重复键；`get` 返回首个匹配。
- `get` / `at` / `val_at` 返回副本。修改嵌套容器时，应先构造子树，再用 `set` 挂回父节点，或直接用 `set_at` / `remove_at` / `remove` 修改已有子项。
- 用例：`tests/stdlib/json/`。

```python
import json

def main() {
    r = json.parse("{\"name\":\"rgc\",\"stars\":42}")
    if r.ok {
        v = r.value
        print(json.as_str(json.get(@v, "name")))   # rgc
        print(json.stringify(@v))                  # {"name":"rgc","stars":42}
    } else {
        print("invalid json:", r.error)
    }
}
```

### 6.12 `os` 系统 / 进程（✅ 已内建）

`os` 是**内建虚拟模块**，函数直接生成 libc 调用。`system(cmd)` 同时保留无前缀的全局内建形式。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 环境变量 | `os.getenv(name: str) -> Maybe[str]` | 不存在时返回 `Nothing` | ✅ |
| 设置环境变量 | `os.setenv(name: str, value: str)` | 覆盖已有值（overwrite=1） | ✅ |
| 退出 | `os.exit(code: int)` | 立即终止进程，退出码取低 8 位 | ✅ |
| 运行命令 | `system(cmd: str) -> int` / `os.system(cmd)` | 执行 shell 命令，返回退出码 | ✅ |
| 当前目录 | `os.getcwd() -> Result[str, str]` | 成功返回路径，失败返回 Err | ✅ |

### 6.13 `args` 命令行参数（✅ 已内建）

> Python 参考：`sys.argv`；Rust 参考：`std::env::args`。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 参数列表 | `args() -> List[str]` | 含程序名（`argv[0]`），同 Python `sys.argv` | ✅（内建：`main` 编译为 `int main(int argc, i8** argv)`，`args()` 返回 `List[str]` 视图） |

- 已实现：`args()` 返回 `List[str]`，`data` 指向 `argv`、`len`/`cap` 为 `argc`；字符串指向进程内存，无需拷贝/释放。
- 示例：

```python
def main() {
    for a in args() {
        print(a)
    }
}
```

### 6.14 `regex` 正则表达式（✅ 源码模块）

> Python 参考：`re`；Rust 参考：`regex` crate。

`regex` 是 **RGC 源码模块**（`lib/regex.rg`），纯 RGC 回溯引擎，按字节匹配。编译结果用 `Regex { ok, error, root, ngroups }` 承载（同 JSON，避免自定义 `Result` 载荷限制）。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 编译 | `compile(pattern: str) -> Regex` | 语法错误时 `ok=False`，`error` 给出原因 | ✅ |
| 匹配 | `is_match(rx: @Regex, text: str) -> bool` | 任意位置搜索（`re.search` 语义） | ✅ |
| 查找 | `find(rx: @Regex, text: str) -> int` | 首个匹配起点；无匹配返回 `-1` | ✅ |
| 搜索 | `search(rx: @Regex, text: str) -> ReMatch` | 最左优先匹配，返回整体区间与捕获组 | ✅ |
| 替换 | `replace(rx: @Regex, text: str, repl: str) -> str` | 替换全部非重叠匹配；含捕获组时展开 `$0`–`$9` / `${n}` | ✅ |

- 支持：字面量、`.`、`*`、`+`、`?`、`{m}` / `{m,}` / `{m,n}`、`|`、捕获组 `(...)`、非捕获组 `(?:...)`、`[...]`、`[^...]`、`^`、`$`、`\d`、`\w`、`\s`、`\b` / `\B`、反向引用 `\1`–`\99` 与转义（`\n` / `\t` / `\r` / `\f` / `\v`）。
- 量词默认贪婪；追加 `?` 变为惰性：`*?`、`+?`、`??`、`{m,n}?`。回溯顺序决定匹配边界，`search` 返回该起点下的首个优先匹配。
- `ReMatch`：`ok`、`start` / `end`（字节偏移，左闭右开）、`groups`。`groups[0]` 是整体匹配，`groups[i]` 是第 i 个捕获组；未参与匹配的组为空串。`Regex.ngroups` 给出捕获组数量。
- 重复量词中的捕获组按**最后一次迭代**取值（如 `(a|b)+` 匹配 `"ab"` 时组 1 为 `"b"`）；反向引用引用未参与匹配的组时匹配失败；前向引用与超出已有组数的编号在编译期报错。
- 替换展开：`$0`–`$9`、`${n}` 引用捕获组（越界或未参与匹配展开为空串），`$$` 表示字面 `$`。仅当模式含捕获组时展开，否则 `repl` 原样写入。
- 词边界按 `[A-Za-z0-9_]` 判定；字符类内的 `\b` 表示退格符（0x08）。
- 不支持：Unicode 字符类（按字节匹配）、lookaround（`(?=...)` 等）、命名组。
- 非法模式（如 `a(b`、`[z-a]`、`a{3,1}`、`\1(a)`）返回 `ok=False`；回溯引擎在极端模式下可能指数级变慢，递归深度与重复次数成正比。
- 用例：`tests/stdlib/regex/`。

```python
import regex

def main() {
    rx = regex.compile("^(ab)+c?$")
    if rx.ok {
        print(regex.is_match(@rx, "ababc"))      # True
        print(regex.is_match(@rx, "abx"))        # False
        print(regex.replace(@rx, "ababc", "-"))  # -
    } else {
        print("bad pattern:", rx.error)
    }
    word = regex.compile("\\bcat\\b")
    print(regex.is_match(@word, "a cat!"))       # True
    print(regex.is_match(@word, "concat"))       # False

    pair = regex.compile("(\\w+)@(\\w+)")
    m = regex.search(@pair, "mail: user@host")
    if m.ok {
        print(m.groups.get(1), m.groups.get(2))             # user host
        print(regex.replace(@pair, "user@host", "$2:$1"))   # host:user
    }
    repeat = regex.compile("(\\w)\\1")
    print(regex.is_match(@repeat, "hello"))      # True
    lazy = regex.compile("<(.+?)>")
    lm = regex.search(@lazy, "<a><b>")
    print(lm.groups.get(0))                      # <a>
}
```

### 6.15 `bytes` 二进制缓冲区与文件 IO（✅ 源码模块）

> Python 参考：`bytes` / `bytearray`；Rust 参考：`Vec<u8>`。

`bytes` 是 **RGC 源码模块**（`lib/bytes.rg`）。`Bytes` 由裸指针 `data` + `len` / `cap` 表示，读写不经过 C 字符串，NUL 字节原样保留；`io`（§6.7）按 `strlen` 语义处理文本，二进制数据必须走本节 API。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 新建 | `bytes_new(cap: int) -> Bytes` | 分配容量，`len=0`、零填充 | ✅ |
| 从字符串 | `bytes_from_str(s: str) -> Bytes` | 复制 `s` 的字节（不含结尾 NUL） | ✅ |
| 从内存 | `bytes_from_mem(p: str, n: int) -> Bytes` | 复制裸指针的 `n` 字节 | ✅ |
| 拼接 | `bytes_concat(a: @Bytes, b: @Bytes) -> Bytes` | 返回新缓冲区 | ✅ |
| 读文件 | `read_bytes(path: str) -> BytesFileResult` | 一次性读入整个文件（二进制安全） | ✅ |
| 写文件 | `write_bytes(path: str, data: @Bytes) -> BytesFileResult` | 覆盖写入（`O_CREAT|O_TRUNC`），循环 `pwrite` | ✅ |

- `Bytes` 方法：`push` / `get` / `set` / `slice` / `append` / `append_mem` / `to_str` / `find` / `find_byte` / `starts_with` / `has_nul` / `truncate` / `drop_front` / `clear`；`len` 是字段（无括号）。
- `BytesFileResult { ok, error, data, size }`：语言暂不支持 `Result[自定义类型]`，文件结果用带 `ok`/`error` 的包装类承载。错误文案：`cannot open file`、`cannot read file`、`short read`、`short write`。
- 用例：`tests/stdlib/bytes_io/`。

```python
import bytes

def main() {
    b = bytes.bytes_new(4)
    b.push(0)
    b.push(255)
    w = bytes.write_bytes("/tmp/rgc.bin", @b)
    r = bytes.read_bytes("/tmp/rgc.bin")
    print(w.ok, r.ok, r.size, r.data.get(1))   # True True 2 255
}
```

### 6.16 `tar` 归档（✅ 源码模块）

> Python 参考：`tarfile`；Rust 参考：`tar` crate。

`tar` 是 **RGC 源码模块**（`lib/tar.rg`），纯 RGC 实现，不依赖 libarchive。读取支持 POSIX ustar（含 `prefix` 长路径）、GNU LongLink（`L`/`K` 记录）、PAX 扩展头（`x`/`g` 中的 `path`/`linkpath`/`size`/`mtime`）；写入 ustar 头，超过 100 字节的名字自动生成 GNU LongLink 记录。

| API | 签名 | 说明 | 状态 |
|-----|------|------|------|
| 列出 | `list_entries(src: @Bytes) -> TarResult` | 解析全部条目；失败时 `ok=False` 并给出 `error` | ✅ |
| 提取 | `extract(src: @Bytes, name: str) -> TarFileResult` | 按名字取普通文件；目录/符号链接返回 `not a regular file` | ✅ |
| 打包 | `create(files: @List[TarInput]) -> TarResult` | 写入普通文件（kind 0）与目录（kind 5） | ✅ |
| 构建器 | `builder() -> TarBuilder` | `add_file` / `add_file_mode` / `add_dir` / `add_entry` / `finish` | ✅ |
| 构建器打包 | `create_from(b: TarBuilder) -> TarResult` | 等价于 `b.finish()` | ✅ |

- `TarEntry { name, size, mode, mtime, kind, typeflag, linkname, offset }`；`kind`：0 普通文件、1 硬链接、2 符号链接、3 字符设备、4 块设备、5 目录、6 FIFO、7 其他。
- `TarResult { ok, error, entries, data }`、`TarFileResult { ok, error, data, entry }`、`TarInput { name, data, kind, mode, mtime }`。
- 目录写入时自动补尾 `/`；`mode` 为 0 时文件用 `0644`、目录用 `0755`。
- 错误：`invalid tar checksum`、`truncated tar header`、`truncated tar data`、`invalid tar size`、`empty entry name`、`unsupported entry kind`、`not a regular file`、`entry not found`。
- `.tar.gz` 直接组合 gzip 文件 API（§11.7 压缩行）：`gzip.decompress_file` 后 `tar.list_entries` / `tar.extract`；写侧 `tar.create` + `gzip.compress_to_file`。
- 用例：`tests/stdlib/tar/`；与系统 GNU tar 的双向互操作见 `tests/tar_interop/suite.rg`（`rack test` 运行；ustar/pax/gnu、长名、symlink、`.tar.gz`、二进制文件）。

```python
import bytes
import tar

def main() {
    b = tar.builder()
    payload = bytes.bytes_from_str("hello\n")
    b.add_file("pkg/hello.txt", @payload)
    b.add_dir("pkg/logs")
    made = b.finish()
    archive = made.data
    l = tar.list_entries(@archive)
    print(l.ok, l.entries.len())                 # True 2
    f = tar.extract(@archive, "pkg/hello.txt")
    print(f.ok, f.data.len)                      # True 6
}
```

### 6.17 密码学原语（✅ 源码模块，纯 RGC）

> Python 参考：`hashlib` / `hmac` / `cryptography`；Rust 参考：`sha2` / `aes-gcm` / `x25519-dalek`。

TLS 1.3 所需的密码学原语全部以 **纯 RGC** 实现（共享 `lib/bigint.rg` 大整数/Montgomery 底座），
不链接 OpenSSL 或任何外部密码库。摘要、密钥、标签均为 `bytes.Bytes`；AEAD 输出为“密文‖16 字节 tag”。

| 模块 | 主要 API | 说明 |
|------|----------|------|
| `sha2` | `sha256(@data)` / `sha384(@data)` / `sha512(@data)`；流式 `sha256_new` / `sha256_update(@var s, @data)` / `sha256_finish(@var s)` / `sha256_digest(@s)`，SHA-512 同名 | FIPS 180-4；`sha256_finish` 消费上下文，`sha256_digest` 复制后计算 |
| `hmac` | `sha256(@key, @data)` / `sha384(@key, @data)`；`sha256_parts(@key, @p1, @p2, @p3)` | RFC 2104；`*_parts` 避免拼接临时缓冲 |
| `hkdf` | `extract_sha256` / `expand_sha256(@prk, @info, length)` / `extract_sha384` / `expand_sha384`；`expand_label_sha256/384(@secret, label, @context, length)` | RFC 5869；`expand_label_*` 为 TLS 1.3 的 HKDF-Expand-Label |
| `aes` | `aes_new(@key) -> AesCtx`；`aes_encrypt_block(@ctx, @block16)`；`gcm_seal(@key, @nonce12, @aad, @plaintext) -> Bytes`；`gcm_open(...) -> GcmResult{ok,error,data}` | FIPS-197 + NIST SP 800-38D；AES-128/256；GCM 只提供 AEAD 组合接口 |
| `chacha20poly1305` | `seal(@key32, @nonce12, @aad, @plaintext) -> Bytes`；`open(...) -> ChachaResult{ok,error,data}`；底层 `chacha_block` / `chacha20_xor` / `poly1305` | RFC 8439 |
| `x25519` | `base_public(@priv32)` / `shared_secret(@priv32, @peer_pub32)` / `keypair() -> X25519KeyPair` | RFC 7748；私钥为 32 字节原始标量 |
| `p256` | `base_public(@priv32)` / `shared_secret(...)` / `keypair()`；`ecdsa_sign_hash(@priv, @digest)` / `ecdsa_verify_hash(@pub, @digest, @der_sig)`；`ctx_new_p384()` + `ecdsa_verify_hash_ctx(...)`；`der_parse_sig` / `der_encode_sig` | NIST P-256/P-384 ECDH + ECDSA（SHA-256/SHA-384） |
| `rsa` | `parse_public(@spki_der)` / `parse_private(@der)`；`pkcs1v15_verify` / `pkcs1v15_sign`；`pss_verify(..., salt_len)` / `pss_sign(..., salt_len)`；`hash_bytes(alg, @data)` | PKCS#1 v1.5 与 PSS；摘要 `sha256`/`sha384`/`sha512` |
| `bigint` | `big_from_bytes_be/le`、`big_add` / `big_sub_mod` / `big_mul` / `big_mod`、`mont_new` + `mont_mul` / `mont_pow` / `mont_inv`、`big_to_bytes_be/le` | 定长多字大整数与 Montgomery 模运算 |
| `entropy` | `bytes_random(n)` / `fill_bytes(@var b, n)` / `random_bytes_into(p, n)` | Linux/macOS 读取 `/dev/urandom`，Windows 走 `BCryptGenRandom`；失败返回空 `Bytes` / `False`，调用方必须失败 |

- 用例：`tests/stdlib/crypto/`，对照 RFC 4231（HMAC）、RFC 5869（HKDF）、FIPS-197（AES）、NIST SP 800-38D（GCM）、RFC 8439（ChaCha20-Poly1305）、RFC 7748（X25519）以及 openssl 生成的 ECDSA/RSA 签名向量。
- TLS 1.3 套件：`TLS_AES_128_GCM_SHA256`、`TLS_AES_256_GCM_SHA384`、`TLS_CHACHA20_POLY1305_SHA256`（见 §11.5）。

### 6.18 ASN.1 / X.509 / 公钥（✅ 源码模块）

| 模块 | 主要 API | 说明 |
|------|----------|------|
| `asn1` | `der_next(@data, pos) -> Tlv{ok,tag,start,len,next}`；`der_content`；`der_oid_is` / `der_oid_str`；`base64_decode`；`pem_next(@text, pos) -> PemBlock{ok,label,der,next}` | DER TLV 遍历、OID 点分字符串、Base64 与 PEM 块迭代（可直接喂 CA bundle） |
| `pkey` | `parse_spki(@der)` / `parse_private(@der)`；`verify(@key, scheme, @digest, @sig)` / `sign(...)`；`scheme_fits_key`；`hash_for_scheme(scheme)` | 公钥 SPKI（RSA / P-256 / P-384）；私钥 PKCS#8 / PKCS#1（RSA）/ SEC1（P-256）；scheme 名与 TLS 1.3 一致（`rsa_pss_rsae_sha256`、`ecdsa_secp256r1_sha256` 等） |
| `x509` | `parse(@der) -> X509Cert`；`verify_chain(@leaf, @chain, @store, now) -> X509VerifyResult`；`hostname_matches(@cert, host)`；`store_new` / `store_add_pem(@var st, @pem)` / `store_load_system()`；`verify_signed(@cert, @issuer_pub)` | 证书解析、链构建与校验、DNS/IP SAN 匹配、系统 CA 加载 |

- `X509Cert` 字段：`subject` / `issuer` / `serial` / `not_before` / `not_after` / `spki` / `pub` / `san_dns` / `san_ips` / `cn` / `is_ca` / `path_len` / `key_usage` / `eku_server` / `eku_client` / `unsupported_critical`。
- 校验项：有效期（调用方传入 `now`）、CA `basicConstraints` 与 `path_len`、`keyUsage`（`keyCertSign` / `digitalSignature`）、EKU serverAuth、未知 critical 扩展拒绝、签名算法一致（RSA PKCS#1 v1.5/PSS、ECDSA P-256/P-384）；链深上限 10，支持交叉签名根。
- 系统 CA：优先 `SSL_CERT_FILE`，否则依次尝试 `/etc/ssl/certs/ca-certificates.crt`、`/etc/pki/tls/certs/ca-bundle.crt`、`/etc/ssl/ca-bundle.pem`、`/etc/ssl/cert.pem`、`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`。目录式 store（`SSL_CERT_DIR`）不扫描（RGC 当前无 `readdir`）。
- 主机名匹配：DNS 名按 SAN `dNSName` 通配符规则逐级比较（大小写不敏感），IPv4 字面量按 SAN `iPAddress` 精确比较；仅当证书没有任何 SAN 时回退 CN。

---

## 7. `format` 字符串格式化（✅ 已实现，含格式说明符）

```python
format(fmt: str, args...) -> str
```

- `fmt` 必须是**字符串字面量**，其中每个 `{...}` 按顺序替换为一个实参。
- 实参支持 `int` / `float` / `bool` / `str`；`{}` 与 `to_string` 规则一致。
- `{{` / `}}` 产生字面量 `{` / `}`，不占位。
- 占位符数量必须与实参数量一致，说明符在编译期按实参类型校验。
- 运行时通过一次分配 + 拼接生成结果字符串。

说明符语法（方括号表示可选）：

```
{:[align][+][#][0][width][.precision][type]}
```

当前支持的子集：

| 部分 | 取值 | 说明 |
|------|------|------|
| `align` | `<` / `>` / `^` | 左/右/居中；数字默认右对齐，`str`/`bool` 默认左对齐 |
| `+` | — | 数字始终显示正负号 |
| `#` | — | 整数加 `0x`/`0o`/`0b` 前缀；浮点保留小数点 |
| `0` | — | 数字宽度不足时补零（需配合 `width`，不能与 `^` 同用） |
| `width` | 十进制数字 | 最小字段宽度（按字节计） |
| `.precision` | 十进制数字 | 浮点小数位数；`str` 截断到前 N 字节 |
| `type` | `d` / `x` / `X` / `o` / `b` | 整数：十进制/十六进制/大写十六进制/八进制/二进制（64 位补码） |
| `type` | `f` / `e` / `E` / `g` / `G` | 浮点：定点/科学计数（默认 `g`） |
| `type` | `s` | 字符串/布尔 |

示例：

```python
def main() {
    print(format("x = {}, ok = {}", 42, True))            # x = 42, ok = True
    print(format("{:08x} {:#b} {:+d}", 255, 5, 7))        # 000000ff 0b101 +7
    print(format("{:.2f} {:>8s}", 3.14159, "hi"))         # 3.14       hi
    print(format("{{{}}}", 1))                            # {1}
}
```

不支持：位置参数（`{0}`）、命名参数、自定义 fill 字符、动态宽度/精度；仍需拼接时可用 `to_string` + `+`。f-string 语法扩展推迟（§14）。

---

## 8. 文件 IO 示例

Phase 8 里程碑：用 RGC 写 `cat` 克隆。

```python
import io  # 内建模块：无源文件，`read_file`/`write_file` 由编译器提供

def main() {
    path = "examples/hello.rg"
    match read_file(path) {
        case Ok(content) => print(content)
        case Err(msg)    => print("error:", msg)
    }
}
```

`cat` 克隆核心：

```python
import io

def main() {
    first = True
    for path in args() {
        if not first {
            match read_file(path) {
                case Ok(content) => print(content)
                case Err(msg)    => print("cat:", msg)
            }
        }
        first = False
    }
}
```

二进制文件（压缩包、归档、图片等含 NUL 的数据）不能用 `io.*`：`str` 以 NUL 结尾，读写会截断。改用 `bytes`（§6.15）：

```python
import bytes

def main() {
    data = bytes.bytes_new(3)
    data.push(0)
    data.push(1)
    data.push(255)
    print(bytes.write_bytes("/tmp/rgc.bin", @data).ok)   # True
    back = bytes.read_bytes("/tmp/rgc.bin")
    print(back.ok, back.size, back.data.get(2))          # True 3 255
}
```

---

## 9. 模块系统（✅ 已实现）

### 9.1 语法

```python
# 引入模块
import io
import math

# 模块内公开声明
public def read_file(path: str) -> Result[str, str] { ... }
```

### 9.2 规则

- `import foo` 解析顺序：入口文件目录 `foo.rg` 优先；再搜索 `RGC_STD`（冒号分隔）、编译器可执行文件上溯 4 级的 `lib/` 与 `lib/rgc/`、`/usr/local/lib/rgc`、`/usr/lib/rgc`。
- `io` / `time` / `random` / `os` / `asyncio` 是**内建虚拟模块**（无源文件，且不允许项目同名文件覆盖）。
- 标准库源码模块（`lib/json.rg`、`lib/regex.rg`、`lib/string.rg`、`lib/list.rg`、`lib/path.rg`）通过同一搜索路径解析。
- 默认符号**不导出**，`public` 标记对外可见；私有函数按 `module$name` 隔离，不同模块同名私有函数互不冲突。
- 模块文件后缀 `.rg`；循环 import 为编译错误，重复 import 按路径缓存去重。
- 目录包（`foo/bar`）暂未支持。

---

## 10. 异步编程（✅ 一任务一线程）

> 已落地：`async def` / `await` / `asyncio.run` / `asyncio.gather` / `asyncio.wait_any` /
> `Task.done` / `Task.wait` / `Task.cancel` / `asyncio.cancelled` 由编译器直接生成 pthread
> 调用，不依赖闭包与事件循环。`asyncio` 是内建虚拟模块。

### 10.1 语义

- `async def f(...) -> T` 声明异步函数；调用**不执行函数体**，而是立即派生线程并返回 `Task[T]`。
- `await task` 阻塞当前线程直到目标任务结束并取回返回值；`await` 只能出现在 `async def` 内。
- `asyncio.run(task)` 是同步桥：在普通函数（通常 `main`）中等待任务完成并返回载荷。
- `asyncio.gather(tasks)` 等待一组任务并返回 `Task[List[T]]`：入参必须是可移动的
  `List[Task[T]]` 变量，结果按入参顺序排列；空列表返回空列表。gather 本身也是任务，
  可再被 `await` 或传给 `asyncio.run`，因此可与其他任务并行。
- `asyncio.wait_any(tasks)` 轮询一组任务，返回**首个已完成任务的下标**（按列表顺序扫描；
  若无已完成任务则约每 1ms 重试，直到有一个完成）；空列表直接返回 `-1`。`wait_any`
  **不消费任务**，也不消费列表：返回后仍可 `await` 对应任务、`cancel` 其余任务或再次
  `wait_any`（对照 Python `asyncio.wait(..., return_when=FIRST_COMPLETED)`、
  JS `Promise.race` 取下标而非结果）。
- `task.done()` 查询任务是否已结束（`bool`），不阻塞；`await` 之后任务变量被消费，
  不能再调用 `done()`。
- `task.wait(ms)` 最多等待 `ms` 毫秒（`<= 0` 只查一次）：任务完成返回 `True`，超时返回
  `False`。`wait` **不消费任务**，返回 `False` 后可继续 `wait` / `done` / `await`；
  它只放弃等待，不取消或中断任务（对照 C# `WaitAsync`、`Future.result(timeout)`）。
- `task.cancel()` **协作式**记录取消请求：任务未完成且此前未请求时返回 `True`，已完成或
  重复请求返回 `False`。它不终止线程、不消费任务（对照 C# `CancellationTokenSource.Cancel`、
  Go `context.CancelFunc`）。
- `task.cancelled()` 查询请求标志；`asyncio.cancelled()` 查询**当前任务**的标志（任务外
  恒为 `False`）。任务需自行轮询并在安全点返回；忽略请求的任务会照常跑完。
- RGC 不会像 Python `Task.cancel()` 那样在 `await` 点注入异常，也没有强制终止：多线程
  后端下强杀线程可能破坏锁与已分配资源，因此采用 Go / C# 的协作模型。
- `Task[T]` 是内建泛型类（字段 `handle: int`），用户不能直接构造，只能由 async 调用产生。
- `await` / `gather` 消费任务：同一个 `Task` 变量只能等待一次（重复等待是编译错误）。
- 可 `await` 任意 `Task[T]` 表达式，包括 `List[Task[int]]` 的元素与另一个 async 函数的返回值（嵌套）。

### 10.2 与其他语言对照

| 能力 | Python asyncio | Rust tokio / futures | Go goroutine | JS Promise | C# Task | RGC |
|------|----------------|----------------------|--------------|------------|---------|-----|
| 启动任务 | `asyncio.create_task(coro)` | `tokio::spawn(fut)` | `go f()` | 调用 async 函数 | `Task.Run(f)` | 调用 `async def` |
| 等待单个 | `await t` | `t.await` | channel 接收 | `await p` | `await t` | `await t` / `asyncio.run(t)` |
| 等待全部 | `asyncio.gather(*ts)` | `futures::join_all` / `tokio::join!` | `sync.WaitGroup` | `Promise.all` | `Task.WhenAll` | `asyncio.gather(list)` |
| 等待任一 | `asyncio.wait(..., FIRST_COMPLETED)` | `futures::select!` / `join!` 无下标 | `reflect.Select` 多路 | `Promise.race` | `Task.WhenAny` | `asyncio.wait_any(list)`（返回下标） |
| 完成查询 | `t.done()` | `t.is_finished()` | 无内建 | 无内建 | `t.IsCompleted` | `t.done()` |
| 结果收集 | gather 返回 list | join 返回 Vec | 结果需自建 | thenable 数组 | `Task<T[]>.Result` | gather 返回 `Task[List[T]]` |
| 取消 | `t.cancel()`（在 await 点注入异常） | `AbortHandle`（丢弃 future） | `context.WithCancel`（协作） | `AbortController`（协作） | `CancellationToken`（协作） | `t.cancel()` + `asyncio.cancelled()`（协作） |
| 超时等待 | `asyncio.wait_for`（超时取消） | `tokio::time::timeout`（丢弃 future） | `context.WithTimeout`（取消） | `AbortSignal.timeout`（中止） | `Task.WaitAsync`（不取消） | `t.wait(ms)`（不取消） |
| 调度模型 | 单线程事件循环 | 多线程 runtime | M:N 调度 | 单线程事件循环 | 线程池 + 调度器 | 一任务一线程 |

RGC 的取舍：不引入闭包与 future 状态机，直接用 pthread 换实现的简单性；`gather` 在专有
线程内按顺序 join，语义与 `Promise.all` / `Task.WhenAll` 一致（结果按入参顺序）。取消
采用协作标志而非注入异常或强杀线程，与 Go `context` / C# `CancellationToken` 一致。

### 10.3 示例

```python
import asyncio
import time

class Point {
    x: int
    y: int
}

async def add_async(a: int, b: int) -> int {
    time.sleep(0.02)
    return a + b
}

async def make_point(x: int, y: int) -> Point {
    p = Point()
    p.x = x
    p.y = y
    return p
}

async def driver() {
    print(await add_async(40, 2))          # 42
    p = await make_point(3, 4)             # 自定义类型载荷
    print(p.x, p.y)                        # 3 4
}

def main() {
    asyncio.run(driver())
    print(asyncio.run(add_async(1, 2)))    # 3（也可直接桥接单个任务）
}
```

并发：先连续创建多个任务、之后再 `await`，任务即并行执行。

```python
async def slow() -> int {
    time.sleep(0.25)
    return 1
}

async def parallel() -> bool {
    a = slow()
    b = slow()
    return (await a) + (await b) == 2      # 总耗时约 0.25s，而非 0.5s
}
```

gather 与完成查询：

```python
import asyncio
import time

async def slow() -> int {
    time.sleep(0.25)
    return 1
}

async def joined() -> List[int] {
    ts = List[Task[int]]()
    ts.push(slow())
    ts.push(slow())
    return await asyncio.gather(ts)        # gather 也是任务；结果按入参顺序
}

def main() {
    t = slow()                             # 0.25s
    print(t.done())                        # False（多半还没跑完）
    vals = asyncio.run(joined())
    print(vals.len())                      # 2
}
```

`gather` 消费任务列表；列表变量在调用后不可再用，元素任务也不能单独 `await`。

等待任一（返回下标，不消费任务，便于再做取消 / 超时 / 逐个收集）：

```python
async def slow() -> int {
    time.sleep(0.25)
    return 1
}

async def fast() -> int {
    time.sleep(0.02)
    return 2
}

async def first_done() -> int {
    ts = List[Task[int]]()
    a = slow()                             # 0.25s
    b = fast()                             # 0.02s
    ts.push(a)
    ts.push(b)
    i = asyncio.wait_any(ts)               # 1（b 先完成）
    v = await ts.get(i)                    # 先收下结果
    a.cancel()                             # 其余任务可协作取消
    print(await a)                         # -1（任务自行轮询后返回）
    return v
}
```

超时等待（`wait` 不消费任务，超时后任务继续运行）：

```python
async def waits() {
    t = slow()
    print(t.wait(100))                     # False（0.25s 任务，100ms 超时）
    print(t.wait(1000))                    # True（已等够）
    print(await t)                         # 1（wait 不消费任务）
}
```

协作式取消（任务自行轮询 `asyncio.cancelled()`）：

```python
async def worker() -> int {
    i = 0
    while i < 100 {
        if asyncio.cancelled() {
            return -1                     # 在安全点退出
        }
        time.sleep(0.01)
        i = i + 1
    }
    return 0
}

async def cancels() {
    t = worker()
    print(t.cancel())                     # True
    print(t.cancelled())                  # True
    print(await t)                        # -1
}
```

### 10.4 运行时布局

| 结构 | LLVM 类型 | 说明 |
|------|-----------|------|
| `Task[T]` | `%Task$<payload>` | `{ i64 handle }`，`handle` 实际存放 `pthread_t` |
| 结果盒 | `%TaskBox$<payload>` | `{ i64 tid, i64 done, T payload, i64 cancel }`，堆分配，`await` 后 `free` |
| 参数块 | `%TaskArgs$<fn>` | `{ ptr box, params... }`，堆分配，由包装函数 `free` |
| 包装函数 | `void @<fn>$task(ptr %args)` | 编译器生成：加载参数 → 调用真实函数 → 写回结果盒 |
| gather 参数块 | `%GatherArgs$<payload>` | `{ ptr box, ptr tasks_data, i64 tasks_len }`，堆分配 |
| gather 包装函数 | `void @__rgc_gather$<payload>$task(ptr %args)` | 逐个 `pthread_join` 输入任务 → 结果 `push` 进 `List` → 写回结果盒 |

- async 调用：`malloc` 结果盒与参数块 → `pthread_create`（tid 直接写入盒首字段）→ 返回 `Task` 结构。
- `await`：`extractvalue` 取句柄；在任务线程内先以 1ms 轮询子任务 `done` 与父任务取消标志
  （父任务被取消时把子任务取消标志置 1），完成后再 `pthread_join`；顶层 `asyncio.run`
  （不在任务线程内）直接 join。随后从盒中 load 载荷并 `free` 盒。
- 结果盒 `done` 字段在载荷写完后以单调原子存储置 1；`task.done()` 原子读取该字段，不 join。
- `task.wait(ms)`：每 1ms 原子读取一次 `done` 字段（`nanosleep` 休眠），完成返回 `true`；
  剩余毫秒数耗尽返回 `false`。不 join、不释放结果盒，任务线程继续运行，之后仍可 `await`。
- 取消标志位于结果盒末尾；线程入口把其地址写入 TLS 全局 `@rgc.tls_cancel`，
  `asyncio.cancelled()` 读取该指针（为空表示不在任务线程内）；`task.cancel()` 用原子
  交换记录请求，`task.cancelled()` 原子读取标志。
- `gather`：结果盒载荷为 `List$<payload>`；gather 线程顺序 join 每个输入任务，把载荷
  `push` 进列表，最后写载荷、置 `done`；gather 返回的 `Task` 可用普通 `await` / `asyncio.run` 等待。
- `asyncio.wait_any`：内联生成扫描循环，逐元素原子读取结果盒 `done` 标志；命中即返回下标，
  全部未完成时 `nanosleep` 1ms 后重扫。只读列表数据与 `done` 标志，不 join、不释放结果盒，
  因此不消费任务；空列表在入口直接返回 `-1`。
- 载荷映射：`int` → `i64`、`float` → `double`、`bool` → `i1`、`str` → `ptr`、`None` → 无载荷、自定义类 → `%类名`。
- 用户程序统一以 `-lpthread` 链接（编译器自身已有 shim 链接）。

### 10.5 事件循环（import event）

> `lib/event.rg`：跨平台单线程 selector，基于 `poll(2)` / `WSAPoll`；定时器是
> `time.monotonic_ms()` 截止时间加轮询超时，跨线程唤醒用回环 UDP socket 对；
> 全部通过 `extern def` 调用 libc/Winsock，不依赖闭包或函数指针，也不需要
> epoll/timerfd/socketpair 等 Linux 专有接口。事件循环与 `async def` 的线程模型
> 相互独立：前者等待大量 fd 就绪，后者并行执行任务。

```python
import event
import net

def main() {
    loop = event.new_loop()
    l = net.listen_on("127.0.0.1", 8080)
    listener = l.listener
    listener.set_nonblocking(True)
    loop.add(listener.fd, 1, event.ev_in())

    while True {
        w = loop.wait(-1)                    # 无限等待；0 = 只轮询一次
        i = 0
        while i < w.events.len() {
            e = w.events.get(i)
            if e.token == 1 {
                a = listener.try_accept()
                if a.ok and not a.again {
                    s = a.stream
                    s.set_nonblocking(True)
                    # 注册读写并处理请求
                }
            }
            i = i + 1
        }
    }
}
```

| API | 签名 | 说明 |
|-----|------|------|
| 创建 | `event.new_loop() -> EventLoop` | 创建回环 UDP 唤醒对；失败时 `is_open()` 为 `False`，`error` 为错误文本 |
| 状态 | `EventLoop.is_open() -> bool` | 未关闭 |
| 注册 | `EventLoop.add(fd: int, token: int, events: int) -> EventOp` | 加入 poll 集合；`events` 为 `ev_in()` 等按位组合 |
| 修改 | `EventLoop.modify(fd, token, events) -> EventOp` | 更新注册；未注册的 fd 返回错误 |
| 删除 | `EventLoop.remove(fd: int) -> EventOp` | 移除注册；未注册的 fd 返回错误 |
| 等待 | `EventLoop.wait(timeout_ms: int) -> EventWait` | `< 0` 无限等待，`0` 立即返回，`> 0` 毫秒超时 |
| 单次定时 | `EventLoop.add_timer(token: int, delay_ms: int) -> EventOp` | 到期后返回一次 `ev_timeout()`；`delay_ms=0` 下一轮触发 |
| 周期定时 | `EventLoop.add_interval(token: int, interval_ms: int) -> EventOp` | 首次与后续间隔均为 `interval_ms` |
| 取消定时 | `EventLoop.cancel_timer(token: int) -> bool` | 移除对应定时器 |
| 定时计数 | `EventLoop.timer_count() -> int` | 当前单次 + 周期定时器数量 |
| 唤醒 | `EventLoop.post(token: int) -> bool` | 可跨线程调用；`wait` 返回 `ev_wake()` + token |
| 唤醒 | `event.post_fd(wake_fd: int, token: int) -> bool` | 只持有 `wake_w` 时使用（如另一线程） |
| 关闭 | `EventLoop.close()` | 关闭唤醒对并清空全部注册与定时器；重复调用安全 |
| 事件位 | `event.ev_in()` / `ev_out()` / `ev_err()` / `ev_hup()` / `ev_rdhup()` / `ev_edge()` | 可用 `\|` 组合；`ev_edge()` 仅为兼容保留 |
| 事件位 | `event.ev_timeout()` / `event.ev_wake()` | 定时器 / `post` 事件（`256` / `512`） |

结果类：

```python
public class Event { token: int; events: int }
public class EventOp { ok: bool; error: str }
public class EventWait {
    ok: bool
    error: str
    timeout: bool          # 无事件且未出错（超时或 0 超时轮询）
    events: List[Event]
}
```

行为约定：

- **token**：`0 <= token < 2^62`，同一 loop 内应唯一（fd 与定时器共用命名空间）；
  事件本身不带 fd，调用方用 token 找回状态。
- **事件位**：`ev_in`/`ev_out` 为水平触发；`poll` 没有边沿触发模式，`ev_edge()` 会被接受
  但不改变行为，注册始终是水平触发，需自行把 fd 读到 `EAGAIN`/写到 `EAGAIN`。
  `ev_err`/`ev_hup` 总会报告；`ev_rdhup` 在 Linux 上映射 `POLLRDHUP`。
- **定时器**：定时器只是 `time.monotonic_ms()` 截止时间，不占用 fd；`wait` 把下一个
  截止时间并入 poll 超时，到期后返回 `events = ev_timeout()`。周期定时器按固定间隔续期，
  错过的周期会追赶而不是堆积事件；单次定时器返回后自动移除。
  `add_timer` 重复使用同一 token 会替换旧定时器。
- **唤醒**：`post` 把 8 字节 token 写入回环 UDP socket 对，`wait` 读取后返回
  `events = ev_wake()`；每个报文保留一条消息边界，多次 `post` 各自得到一个事件。
  `post` 线程安全，其余控制操作应在执行 `wait` 的线程调用。
- **错误**：注册/修改/删除失败返回 `ok=False` + `strerror(errno)`；`wait` 失败返回
  `ok=False`；关闭后调用返回 `event loop is closed`，不 panic。
- **已关闭 fd**：未 `remove` 就被 `close` 的 fd 在下一次 poll 报告 `POLLNVAL` 时被静默移除，
  与 epoll 关闭 fd 后自动注销的效果一致。
- **限额**：单次 `wait` 返回的事件数等于就绪 fd 数加到期定时器数，不再有 64 事件上限；
  fd 数量受进程 fd 上限约束，注册表查找为线性扫描。
- **Windows**：`poll` 经运行时 shim 转成 `WSAPoll`（pollfd 与 `WSAPOLLFD` 布局差异在 shim
  内转换），`ev_hup`/`ev_err` 分别对应 Winsock 的 `POLLHUP`/`POLLERR`；唤醒对仍是回环 UDP。
- **非阻塞 IO**：配合 `net.connect_start` / `TcpStream.try_*` / `TcpListener.try_accept`
  与 `udp.UdpSocket.try_*`；它们用 `again=True` 表示 `EAGAIN`，与错误区分。
- **单次就绪**：`event.wait_fd(fd, events, timeout_ms)` 提供一次性的 poll 就绪等待
  （返回 `1` 就绪 / `0` 超时 / `-1` 错误），不必构造 `EventLoop`；`net_async` 用它按
  50 ms 切片等待，从而在 `await` 中同时处理总超时与取消。
- **当前边界**：`async def` 仍是一任务一线程；事件循环驱动的是 **fd 就绪**与超时，
  不是协程调度。`await` 在任务线程内会轮询父任务的取消标志，并把取消转发给正在等待
  的子任务（§10.4）；顶层 `asyncio.run` 仍直接 join。异步流式 HTTP 仍待后续；
  HTTP/2 并发多路复用已由 `http2.get_many` 在协议层提供（§11.6），不依赖事件循环。

### 10.6 限制

- 不支持 `async def main`，需用 `asyncio.run` 桥接。
- 不支持 async 方法、extern async 函数；参数与返回值不能是借用（`@T` / `@var T`）。
- 取消是协作式的：`cancel()` 只置标志，不中断线程；忽略请求的任务会照常跑完。任务应
  在循环或阻塞操作前轮询 `asyncio.cancelled()`。超时用 `task.wait(ms)` 轮询实现
  （粒度约 1ms，仅放弃等待、不终止任务）。任务创建即开始执行。
  `await` 在任务线程内以 1 ms 轮询子任务的完成标志，并轮询父任务取消标志：父任务被
  取消时会把取消转发给正在等待的子任务；顶层 `asyncio.run`（不在任务线程内）直接 join。
  `net_async` 提供基于 `event.wait_fd`（poll）的 TCP/UDP 就绪等待（§11.8）。
- 一任务一线程：任务数受系统线程数限制，`gather` 自身也占用一个线程。
- `gather` 只接受变量形式的 `List[Task[T]]` 并消费它；借用列表、字面量列表与 `Task[None]` 是编译错误。
- `asyncio.wait_any` 只接受 `List[Task[T]]`；空列表返回 `-1`，全部任务都未完成时会阻塞轮询
  （粒度约 1ms）直到有一个完成，因此对可能永不完成的任务集合应配合 `task.cancel()` 使用。
- 丢弃未 `await` 的 `Task` 会泄漏结果盒与参数块（进程退出由 OS 回收）。
- `List` / `Map` 等容器不做跨线程同步，多线程写入需自行保证外部同步。

### 10.7 测试与后续扩展

- `tests/stdlib/async/`：标量 / `str` / `float` / `bool` / 自定义类 / `Result` 载荷、嵌套 await、
  并发重叠计时、`Task[int]` 注解、`List[Task[int]]`、`Task.done` 前后状态、`Task.wait`
  超时 / 零超时 / 完成后查询与不消费语义、协作式取消（任务内轮询提前返回、重复 cancel、
  完成后 cancel、忽略取消）、`gather` 并行计时 / 结果顺序 / `str` 与自定义载荷 / 空列表 /
  `asyncio.run` 桥接、`asyncio.wait_any` 下标 / 不消费语义 / 空列表 / 与取消配合。
- `tests/stdlib/negative/async_*.rg`：await 位置、非 Task、async 方法、async main、
  借用参数、直接构造 Task、重复 await、gather 非 Task 列表、gather `Task[None]`、
  gather 参数个数错误、await 之后调用 `done`、`Task.wait` / `Task.cancel` /
  `Task.cancelled` / `asyncio.cancelled` 参数错误、`asyncio.wait_any` 参数个数 /
  非 `List[Task[T]]`（Task 与 `List[int]`）共 19 类编译错误。
- `tests/stdlib/event/`：fd 注册/修改/删除、超时等待、单次/周期定时器与取消、
  同线程/跨线程 `post`、TCP 非阻塞连接/accept/收发、UDP 非阻塞收发、关闭与错误路径。

| 能力 | 状态 | 说明 |
|------|------|------|
| `async def` / `await` / `asyncio.run` | ✅ | 一任务一线程，见上 |
| `asyncio.gather` | ✅ | 一组任务并行执行、顺序收集结果 |
| `asyncio.wait_any` | ✅ | 返回首个完成任务的下标（空列表 `-1`），不消费任务 |
| `Task.done` | ✅ | 原子查询完成标志，不阻塞 |
| `Task.wait` | ✅ | 轮询完成标志，超时返回 `false`，不消费任务 |
| `Task.cancel` / `asyncio.cancelled` | ✅ | 协作式取消：原子标志 + 任务内轮询，不强制终止 |
| 事件循环（poll） | ✅ | `lib/event.rg`：fd 注册/修改/删除、单调时钟定时器、回环 UDP 跨线程唤醒 |
| 非阻塞网络原语 | ✅ | `net` / `udp` 的 `set_nonblocking`、`try_*`、`connect_start`/`connect_finish`（§11.2/§11.3） |
| 异步网络 | ✅ | `lib/net_async.rg`：poll 就绪等待 + 非阻塞 TCP/UDP，总超时、协作式取消与嵌套 await 取消传播（§11.8）；仍为一任务一线程 |

> 任务数仍受线程数限制；高并发 IO 可用事件循环 + 非阻塞原语，不必一连接一线程。

---

## 11. 网络（✅ 同步 TCP/UDP/HTTP/1.1/HTTP/2/HTTPS）

> 已落地：编译器内建 `tcp_*` 原语直接调用 libc socket，`lib/net.rg`、`lib/udp.rg`、
> `lib/http.rg`、`lib/http2.rg`、`lib/tls.rg`、`lib/https.rg`、`lib/gzip.rg` 用 RGC 自身封装。
> UDP 通过 `extern def` 调用 libc；TLS 为纯 RGC TLS 1.3（`lib/tls.rg`，密码学原语见 §6.17，
> 不链接 OpenSSL 或其他密码库）。
> gzip/deflate 为纯 RGC 实现（`lib/gzip.rg`：DEFLATE、CRC-32/Adler-32），不依赖 zlib。
> `http` 原生支持 `http://` 与 `https://`；HTTPS 通过 ALPN 协商 HTTP/2（选中 `h2` 时走
> `http2`，否则回退 HTTP/1.1），`https` 保留为兼容层。非阻塞原语与 poll 事件循环
> 已落地（§10.5）；异步流式网络封装仍待后续（见 §11.7）。
>
> 语言限制：`Result[T, E]` 暂只支持标量与 `str` 载荷，因此连接/监听/接收结果用
> 带 `ok`/`error` 的包装类承载，而非 `Result[自定义类型]`。

### 11.1 参考语言

| 语言 | 标准库 | 第三方生态 |
|------|--------|-----------|
| Python | `socket`、`http.client`、`urllib` | `requests`、`aiohttp` |
| Rust | `std::net::{TcpStream, TcpListener, UdpSocket}` | `reqwest`、`hyper`、`tokio` |

### 11.2 TCP（`import net`）

```python
import net

def main() {
    l = net.listen("127.0.0.1:0")        # 端口 0 = 内核分配临时端口
    if not l.ok {
        print("listen failed:", l.error)
        return
    }
    listener = l.listener
    port = listener.local_port()

    c = net.connect_to("127.0.0.1", port)
    if not c.ok {
        print("connect failed:", c.error)
        return
    }
    client = c.stream
    a = listener.accept()
    if not a.ok {
        print("accept failed:", a.error)
        return
    }
    server = a.stream

    client.send("ping")
    r = server.recv(64)
    if r.ok {
        print("got:", r.value)           # got: ping
    }
    server.send("pong")
    print(client.recv(64).value)         # pong
    client.close()
    server.close()
    listener.close()
}
```

| API | 签名 | 说明 |
|-----|------|------|
| 连接 | `net.connect(addr: str) -> TcpConnect` | `addr` 形如 `"host:port"`，按最后一个 `:` 切分 |
| 连接 | `net.connect_to(host: str, port: int) -> TcpConnect` | 结构化形式，端口 1–65535 |
| 连接 | `net.connect_timeout(addr: str, timeout_ms: int) -> TcpConnect` | 带连接超时（毫秒，`0` 表示阻塞） |
| 连接 | `net.connect_to_timeout(host: str, port: int, timeout_ms: int) -> TcpConnect` | 结构化 + 超时；`getaddrinfo` 返回的地址逐个尝试 |
| 非阻塞连接 | `net.connect_start(addr: str) -> TcpConnectStart` | 立即返回；`pending=True` 时等可写后调用 `connect_finish` |
| 非阻塞连接 | `net.connect_start_to(host: str, port: int) -> TcpConnectStart` | 结构化形式；自动把套接字设为非阻塞 |
| 连接完成 | `net.connect_finish(stream: TcpStream) -> TcpConnect` | 读取 `SO_ERROR`；失败时关闭 fd |
| 非阻塞 | `net.set_nonblocking(fd: int, on: bool)` | 切换 `O_NONBLOCK` |
| 监听 | `net.listen(addr: str) -> TcpListen` | 地址格式同上；端口 0 表示临时端口 |
| 监听 | `net.listen_on(host: str, port: int) -> TcpListen` | `SO_REUSEADDR`，backlog 128 |
| 解析 | `net.resolve(host: str) -> List[str]` | `getaddrinfo` 返回的地址列表（IPv4/IPv6） |
| 发送 | `TcpStream.send(data: str) -> int` | 阻塞直至全部字节写出；返回实际发送字节数（出错时可能小于 `len`） |
| 发送 | `TcpStream.send_bytes(data: @Bytes) -> int` | 二进制安全（按显式长度） |
| 接收 | `TcpStream.recv(max: int) -> TcpRecv` | 阻塞读取，最多 `max` 字节；`max <= 0` 直接返回空 |
| 接收 | `TcpStream.recv_bytes(max: int) -> TcpRecvBytes` | 二进制安全；`value.len` 为实际字节数 |
| 超时 | `TcpStream.set_timeout(ms: int)` | 设置后续 `send`/`recv` 的 `SO_RCVTIMEO`/`SO_SNDTIMEO` |
| 非阻塞接收 | `TcpStream.try_recv(max) -> TcpRecv` / `try_recv_bytes(max) -> TcpRecvBytes` | 无数据时 `ok=True, again=True`；EOF 时 `again=False`、空值 |
| 非阻塞发送 | `TcpStream.try_send(data) -> TcpSend` | 写出尽可能多字节；`again=True` 表示内核缓冲已满 |
| 非阻塞发送 | `TcpStream.try_send_mem(p, n)` / `try_send_bytes(data: @Bytes)` | 显式长度 / 二进制安全 |
| 非阻塞 | `TcpStream.set_nonblocking(on: bool)` | 切换当前 socket 的 `O_NONBLOCK` |
| 半关闭 | `TcpStream.shutdown_write()` | 发送 FIN，仍可继续接收 |
| 地址 | `TcpStream.local_port()` / `peer_host()` / `peer_port()` | `getsockname` / `getpeername` |
| 关闭 | `TcpStream.close()` | 关闭 socket 并把 `fd` 置 -1，重复调用安全 |
| 接受 | `TcpListener.accept() -> TcpAccept` | 阻塞等待连接 |
| 接受 | `TcpListener.accept_timeout(ms: int) -> TcpAccept` | 带超时；`timeout` 时 `ok=False` |
| 非阻塞接受 | `TcpListener.try_accept() -> TcpAccept` | 无待处理连接时 `ok=True, again=True`；接受的 fd 不自动设为非阻塞 |
| 非阻塞 | `TcpListener.set_nonblocking(on: bool)` | 切换监听 socket |
| 超时 | `TcpListener.set_timeout(ms: int)` | 影响后续 `accept` |
| 端口 | `TcpListener.local_port() -> int` | `getsockname` 读取实际端口 |
| 关闭 | `TcpListener.close()` | 关闭监听 socket |
| Unix | `net.connect_unix(path)` / `connect_unix_timeout(path, ms)` | Unix 域流式套接字 |
| Unix | `net.listen_unix(path)` | Unix 域监听；抽象地址（`@name`）与文件系统路径均支持 |

结果包装类：

| 类型 | 字段 | 说明 |
|------|------|------|
| `TcpConnect` | `ok: bool`、`error: str`、`stream: TcpStream` | 失败时 `stream.fd == -1` |
| `TcpListen` | `ok: bool`、`error: str`、`listener: TcpListener` | 失败时 `listener.fd == -1` |
| `TcpAccept` | `ok: bool`、`again: bool`、`error: str`、`stream: TcpStream` | `again=True` 表示当前无连接 |
| `TcpRecv` | `ok: bool`、`again: bool`、`error: str`、`value: str` | `again=True` 表示 `EAGAIN` |
| `TcpRecvBytes` | `ok: bool`、`again: bool`、`error: str`、`value: Bytes` | 同上，二进制安全 |
| `TcpSend` | `ok: bool`、`again: bool`、`error: str`、`sent: int` | `sent` 为已完成字节数 |
| `TcpConnectStart` | `ok: bool`、`pending: bool`、`error: str`、`stream: TcpStream` | `pending=True` 表示非阻塞连接进行中 |

行为约定：

- **地址**：`"host:port"` 或 `(host, port)`；主机名经 `getaddrinfo` 解析，IPv4 与 IPv6 均可用，
  IPv6 字面量写作 `"[::1]:8080"`；解析失败返回 `strerror`/`gai_strerror` 文本。
- **超时**：连接超时通过非阻塞 `connect` + `poll` 实现，收发超时通过 `SO_RCVTIMEO`/`SO_SNDTIMEO`；
  超时统一返回 `ok=False, error="timeout"`，可与真实错误区分。
- **接收语义**：对端关闭（EOF）时 `recv` 返回 `ok=True, value=""`；真实 socket 错误返回 `ok=False` 并带 `strerror(errno)` 文本。
- **错误**：连接被拒绝、解析失败、端口越界、地址缺 `:` 等均通过 `ok=False` + `error` 返回，不 panic。
- **非阻塞**：`connect_start` 返回 `pending=True` 时注册 `ev_out()`，可写后调用
  `connect_finish`；`try_recv`/`try_send`/`try_accept` 以 `again=True` 表示 `EAGAIN`，
  其余错误仍为 `ok=False`。非阻塞 connect 成功或 `connect_finish` 后套接字仍为非阻塞。
- **Unix 域套接字**：`listen_unix`/`connect_unix` 在 Linux/macOS 支持文件系统路径与
  `@name` 抽象命名空间；Windows 10+ 原生 AF_UNIX 只支持文件系统路径（`@name` 不可用）。
  `listen_unix` 在 `EADDRINUSE` 时用 `lstat` 识别残留 socket 文件并清理后重绑。
- **SIGPIPE**：发送使用 `MSG_NOSIGNAL`，对端提前关闭不会终止进程。
- **内存**：接收字符串为堆分配且当前无 GC（与 `io`/`json` 一致），进程退出时由 OS 回收；
  二进制数据请使用 `Bytes`（`str` 的 `len()` 基于 `strlen`，遇到 NUL 会截断）。

### 11.3 UDP（`import udp`）

```python
import bytes
import udp

def main() {
    b = udp.open("127.0.0.1:0")          # 端口 0 = 内核分配临时端口
    if not b.ok {
        print("bind failed:", b.error)
        return
    }
    s = b.sock
    s.send_to("ping", "127.0.0.1", s.local_port())
    r = s.recv_from(1024)
    if r.ok {
        print(r.data, r.host, r.port)    # ping 127.0.0.1 <port>
    }

    # IPv6
    v6 = udp.open_on("::1", 0)
    if v6.ok {
        v6.sock.send_to("ping6", "::1", v6.sock.local_port())
        print(v6.sock.recv_from(64).host)   # ::1
        v6.sock.close()
    }

    # 二进制载荷 + 读超时
    s.set_timeout(500)
    payload = bytes.bytes_new(2)
    payload.push(0)
    payload.push(255)
    s.send_bytes(payload, "127.0.0.1", s.local_port())
    r2 = s.recv_from(16)
    print(r2.data_bytes.len)             # 2
    s.close()
}
```

| API | 签名 | 说明 |
|-----|------|------|
| 打开 | `udp.open(addr: str) -> UdpBind` | `addr` 形如 `"host:port"`；端口 0 表示临时端口 |
| 打开 | `udp.open_on(host: str, port: int) -> UdpBind` | 结构化形式；IPv4/IPv6/主机名 |
| 发送 | `UdpSocket.send_to(data: str, host: str, port: int) -> UdpSend` | 发送一个数据报；`sent` 为实际字节数 |
| 发送 | `UdpSocket.send_bytes(data: @Bytes, host: str, port: int) -> UdpSend` | 二进制安全发送 |
| 接收 | `UdpSocket.recv_from(max: int) -> UdpRecv` | 阻塞接收一个数据报；超出 `max` 的部分被截断 |
| 非阻塞接收 | `UdpSocket.try_recv_from(max: int) -> UdpRecv` | 无数据报时 `ok=True, again=True` |
| 非阻塞发送 | `UdpSocket.try_send_to(data, host, port) -> UdpSend` | 内核缓冲满时 `again=True` |
| 非阻塞发送 | `UdpSocket.try_send_mem(p, n, host, port)` / `try_send_bytes(data: @Bytes, host, port)` | 显式长度 / 二进制安全 |
| 非阻塞 | `UdpSocket.set_nonblocking(on: bool)` | 切换 `O_NONBLOCK` |
| 超时 | `UdpSocket.set_timeout(ms: int)` | 设置 `SO_RCVTIMEO`/`SO_SNDTIMEO`，超时报 `timeout` |
| 端口 | `UdpSocket.local_port() -> int` | `getsockname` 读取实际端口 |
| 关闭 | `UdpSocket.close()` | 关闭 fd 并置 -1，重复调用安全 |

结果包装类：

| 类型 | 字段 |
|------|------|
| `UdpBind` | `ok: bool`、`error: str`、`sock: UdpSocket` |
| `UdpSend` | `ok: bool`、`again: bool`、`error: str`、`sent: int` |
| `UdpRecv` | `ok: bool`、`again: bool`、`error: str`、`data: str`、`data_bytes: Bytes`、`host: str`、`port: int` |

行为约定：

- **地址**：`getaddrinfo` 解析 IPv4/IPv6/主机名；`open("...")` 的 IPv6 字面量写作 `"[::1]:8080"`，
  `recv_from` 返回数值来源地址（IPv6 如 `::1`）。发送地址族须与绑定 socket 一致，
  否则返回 `address family not supported`。
- **数据报边界**：一次 `recv_from` 对应一个数据报，不会与相邻数据报拼接。
- **空数据报**：对端发送 0 字节时返回 `ok=True, data=""`；`max <= 0` 返回错误。
- **载荷**：`data` 按 C 字符串处理（`strlen` 语义，遇 NUL 截断）；`data_bytes` 保留完整
  字节（含 NUL），`send_bytes` 发送二进制数据。
- **超时**：`set_timeout(ms)` 后收发超时返回 `ok=False, error="timeout"`；`0` 恢复阻塞。
- **关闭后**：`send_to`/`recv_from` 返回 `socket is closed`，`local_port` 返回 -1，不 panic。

### 11.4 HTTP 客户端（`import http`，HTTP/1.1 + HTTP/2，含 HTTPS）

`http` 同时支持 `http://` 与 `https://`（TLS 由 §11.5 的 `tls` 模块提供）。
HTTPS 握手默认携带 ALPN `h2`：服务端选中时走 HTTP/2（§11.6），否则回退 HTTP/1.1；
`http2 = False` 可强制只走 HTTP/1.1。模块级函数是一次性请求；
需要连接复用、Cookie、代理等能力时使用 `http.new_client()`。

```python
import http

def main() {
    r = http.get("https://example.com/")
    if not r.ok {
        print("request failed:", r.error)          # 网络/证书/限额错误
        return
    }
    res = r.response
    print("status:", res.status)                   # 200
    print("type:", http.header(@res, "Content-Type"))
    print("length:", res.body.len(), res.body_bytes.len)

    p = http.post("http://127.0.0.1:8080/echo", "hello")
    print(p.ok, p.response.status)

    # 复用连接 + 自定义头 + Cookie + 重定向。
    c = http.new_client()
    c.headers.push("X-Token: secret")
    c.set_proxy("http://127.0.0.1:3128")
    a = c.get("http://service.invalid/a")
    b = c.get("http://service.invalid/b")          # 同一 keep-alive 连接
    c.close()
}
```

| API | 签名 | 说明 |
|-----|------|------|
| GET | `http.get(url: str) -> HttpResult` | 一次性客户端（`Connection: close`），默认校验证书 |
| GET | `http.get_with(url: str, headers: List[str]) -> HttpResult` | 追加/覆盖请求头（`"Name: value"`） |
| POST | `http.post(url: str, body: str) -> HttpResult` | 追加 `Content-Length` 与 `Content-Type: text/plain` |
| POST | `http.post_with(url, body, headers)` | 同上，附带自定义头 |
| 任意方法 | `http.request(method, url, body)` / `request_with(...)` | 如 `PUT`/`DELETE`/`PATCH`/`HEAD` |
| 二进制体 | `http.request_bytes(method, url, body: @Bytes, headers)` | 请求体二进制安全 |
| 取头 | `http.header(res: @HttpResponse, name: str) -> str` | 大小写不敏感，返回首个匹配值，未找到返回 `""` |
| 取全部头 | `http.header_values(res: @HttpResponse, name: str) -> List[str]` | 如多个 `Set-Cookie` |
| 取 trailer | `http.trailer(res: @HttpResponse, name: str) -> str` | 查询 chunked 响应 trailer，未找到返回 `""` |
| URL | `http.parse_url(url) -> UrlParts` | scheme/host/port/authority/path/query/userinfo/tls |
| URL | `http.resolve_url(base, location) -> str` | 重定向相对地址解析 |
| 编码 | `http.url_encode(s)` / `url_decode(s)` | 百分号编码（空格 → `%20` / `+` → 空格） |
| 查询串 | `http.encode_query(pairs: @List[str])` / `decode_query(q)` | `"k=v"` 列表与查询串互转 |
| 异步 | `http.get_async(url)` / `post_async(url, body)` / `request_async(m, url, body)` | 返回 `Task[HttpResult]`，配合 `asyncio.run` / `asyncio.gather` / `asyncio.wait_any`；一任务一线程 |

`HttpClient`（`http.new_client()`）字段与默认值：

| 字段 | 默认 | 说明 |
|------|------|------|
| `timeout_ms` | 30000 | 单次请求读超时；超时错误文本为 `timeout` |
| `connect_timeout_ms` | 10000 | TCP/TLS 连接与握手超时 |
| `max_redirects` | 10 | 超过返回 `too many redirects` |
| `max_body` | 32 MiB | 解压前与解压后的正文上限（`0` 表示不限制） |
| `max_header` | 64 KiB | 单个响应头上限，超出 `response header too large` |
| `max_idle` | 8 | 连接池空闲连接上限 |
| `proxy` | `""` | `http://host:port` 或 `https://host:port`；也可用 `set_proxy` |
| `ca_file` | `""` | 自定义 PEM CA；`""` 用系统 CA 包（§6.18） |
| `client_cert` | `""` | 客户端证书（PEM）；非空时启用 mTLS，也可用 `set_client_cert` |
| `client_key` | `""` | 客户端私钥（PEM）；为空时复用 `client_cert` |
| `verify_tls` | True | 是否校验证书链与主机名 |
| `http2` | True | HTTPS 是否通过 ALPN 协商并启用 HTTP/2（False 只走 HTTP/1.1） |
| `keep_alive` | True | 是否复用连接 |
| `follow_redirects` | True | 是否自动跟随 3xx |
| `compress_request` | False | 请求体 gzip 压缩并追加 `Content-Encoding: gzip` |
| `headers` | `[]` | 每个请求附加的头 |
| `cookies` | `[]` | 客户端 Cookie 罐（按域名/路径/secure 匹配） |

客户端方法：`get` / `get_with` / `post` / `post_with` / `request` / `request_with` /
`request_bytes`、`add_header(name, value)`（追加）、`set_header(name, value)`（覆盖）、
`set_proxy`、`set_ca_file`、`set_client_cert(cert_file, key_file)`、`clear_cookies`、
`cookie_header`、`store_cookies`、`put_cookie`、`delete_cookie`、`close`。

异步入口仅提供模块级 `get_async` / `post_async` / `request_async`（一次性连接）；
`HttpClient` 仍是同步对象，可在不同任务中各自创建使用：

```python
import asyncio
import http

def main() {
    tasks = List[Task[HttpResult]]()
    tasks.push(http.get_async("https://example.com/a"))
    tasks.push(http.get_async("https://example.com/b"))
    rs = asyncio.run(asyncio.gather(tasks))
    print(rs.len(), rs.get(0).ok, rs.get(1).ok)
}
```

结构：

```python
public class HttpResponse {
    status: int
    version: str            # "HTTP/1.1" 或 "HTTP/2"
    headers: List[str]      # 原始 "Name: value" 行，按响应顺序
    trailers: List[str]     # chunked trailer（"Name: value" 行）
    body: str               # 解压后的正文（strlen 语义，二进制请用 body_bytes）
    body_bytes: Bytes       # 解压后的正文（二进制安全）
    url: str                # 最终 URL（跟随重定向后）
}

public class HttpResult {
    ok: bool
    error: str
    response: HttpResponse
}
```

行为约定：

- **URL**：`http://host[:port][/path][?query]` 与 `https://...`（默认 443）；
  `user:pass@host` 自动生成 `Authorization: Basic`；其他协议返回 `unsupported URL scheme`。
- **请求**：默认补 `Host`、`User-Agent: rgc-http/1.1`（HTTP/2 下为 `rgc-http/2`）、
  `Accept: */*`、`Accept-Encoding: gzip, deflate`、`Connection: keep-alive`
  （`keep_alive=False` 时为 `close`）与 Cookie；自定义头优先，不覆盖同名内建头。
- **连接池**：按 `(host, port, scheme)` 复用；归还前检查对端是否已关闭；复用前用
  `MSG_PEEK` 检测陈旧连接，失败自动重试一次。
- **响应读取**：支持 `Content-Length`、`Transfer-Encoding: chunked`（chunk 扩展跳过，
  trailer 存入 `res.trailers`，可用 `http.trailer` 查询）、无长度时读到关闭、
  `HEAD`/`204`/`304`/`101` 无正文；自动跳过 1xx（如 `100 Continue`）。
- **压缩**：`gzip`/`x-gzip`/`deflate` 自动解压（`lib/gzip.rg`，纯 RGC DEFLATE，无 zlib 依赖）；解压输出受 `max_body` 约束，超限返回 `response body too large`（防解压炸弹）；
  `compress_request=True` 时请求体 gzip 压缩；其他 `Content-Encoding` 返回
  `unsupported content-encoding`。
- **重定向**：301/302/303 将非 GET/HEAD 改为 GET 并丢弃正文；307/308 保留方法与正文；
  跨主机时去掉 `Authorization` 与 `Host`；相对 `Location` 按 RFC 3986 合并。
- **Cookie**：解析 `Set-Cookie` 的 `Domain`/`Path`/`Secure`/`Max-Age`，按域/路径匹配、
  去重覆盖；`clear_cookies` 清空。不提供持久化存储。
- **代理**：明文 URL 使用 absolute-form 请求行；HTTPS URL 先 `CONNECT host:port`（支持
  `Proxy-Authorization: Basic`），再在隧道上做 TLS。
- **协议协商**：HTTPS 握手提供 ALPN `h2`/`http/1.1`，服务端选中 `h2` 时改走
  HTTP/2（`res.version == "HTTP/2"`，trailer 同样写入 `res.trailers`），否则用
  HTTP/1.1；`HttpClient` 的 HTTP/2 路径按请求顺序复用连接，需要并发多流时直接调用
  `http2.get_many`（§11.6）；`http2=False` 可关闭协商。
  HTTP/2 仅支持 TLS（不支持 h2c），明文 `http://` 始终走 HTTP/1.1。
- **去重头**：HTTP/2 下由 `http2` 过滤连接级头（`Connection`/`Keep-Alive`/
  `Transfer-Encoding` 等）并补 `:method`/`:scheme`/`:authority`/`:path` 伪头。
- **限额与超时**：正文/头超限分别返回 `response body too large` / `response header too large`；
  读超时返回 `timeout`；连接失败返回 `strerror` 文本。
- **借用写法**：`@` 只能作用于变量，查询头部需先 `res = r.response` 再 `http.header(@res, ...)`。
- **未实现**：异步流式客户端（`await` 尚未接入事件循环；事件循环本身见 §10.5）。

### 11.5 HTTPS / TLS（`import tls`；`https` 为兼容层）

`https://` 已由 §11.4 的 `http` 原生支持；`https` 模块保留为兼容层，
内部调用 `http` 并把 `verify_tls` 设为 False（`get_insecure`/`post_insecure`）。

```python
import http
import https
import tls

def main() {
    r = https.get("https://example.com/")
    if r.ok {
        print(r.response.status)
        print(http.header(@r.response, "Content-Type"))
        print(r.response.body)
    } else {
        print("request failed:", r.error)      # 证书/网络错误
    }

    # 自签名或本地测试：跳过证书校验
    local = https.get_insecure("https://127.0.0.1:8443/")
    print(local.ok)

    # 低层 TLS：自定义收发协议
    c = tls.connect("example.com", 443, 10000, True)
    if c.ok {
        s = c.conn
        s.send("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        print(s.recv(4096).value)
        s.close()
    }

    # mTLS：携带客户端证书（PEM）
    m = tls.connect_mtls("service.internal", 443, 10000, True,
                         "", "client.pem", "client.key")
    print(m.ok)
}
```

| API | 签名 | 说明 |
|-----|------|------|
| GET | `https.get(url: str) -> HttpResult` | 校验证书链与主机名/IP；响应类型与 http 相同 |
| POST | `https.post(url: str, body: str) -> HttpResult` | `Content-Type: text/plain` |
| GET | `https.get_insecure(url)` | 跳过证书校验，仅供本地/自签名服务 |
| POST | `https.post_insecure(url, body)` | — |
| 连接 | `tls.connect(host, port, timeout_ms, verify) -> TlsResult` | `verify=True` 校验证书；超时单位毫秒 |
| 连接 | `tls.connect_with_ca(host, port, timeout_ms, verify, ca_file) -> TlsResult` | 显式 PEM CA 文件；`ca_file=""` 用系统 CA 包（见 §6.18） |
| 连接 | `tls.connect_mtls(host, port, timeout_ms, verify, ca_file, cert_file, key_file) -> TlsResult` | 同上，并携带客户端证书（`key_file=""` 时复用 `cert_file`） |
| 连接 | `tls.connect_on(tcp, server_name, verify, ca_file, timeout_ms) -> TlsResult` | 在已建立的 `net.TcpStream` 上握手（代理 CONNECT） |
| 连接 | `tls.connect_on_mtls(tcp, server_name, verify, ca_file, cert_file, key_file, timeout_ms) -> TlsResult` | 同上，并携带客户端证书 |
| 连接 | `tls.connect_alpn(host, port, timeout_ms, verify, ca_file, cert_file, key_file, offer_h2) -> TlsResult` | 握手时提供 ALPN（`h2`/`http/1.1`）；`offer_h2=False` 仅提供 `http/1.1` |
| 连接 | `tls.connect_on_alpn(tcp, server_name, verify, ca_file, cert_file, key_file, timeout_ms, offer_h2) -> TlsResult` | 在已建立 TCP 上握手并协商 ALPN（代理 CONNECT + HTTP/2） |
| ALPN | `TlsConn.get_alpn() -> str` | 协商结果（`h2` / `http/1.1` / `""`） |
| 发送 | `TlsConn.send(data: str) -> int` | 阻塞写完全部字节；出错返回已写字节数 |
| 发送 | `TlsConn.send_bytes(data: @Bytes) -> int` | 二进制安全 |
| 接收 | `TlsConn.recv(max: int) -> net.TcpRecv` | 最多 `max` 字节；对端关闭返回 `ok=True, value=""` |
| 接收 | `TlsConn.recv_bytes(max: int) -> net.TcpRecvBytes` | 二进制安全（显式长度） |
| 版本 | `TlsConn.get_version() -> str` | 如 `TLSv1.3` |
| 关闭 | `TlsConn.close()` | 发送 `close_notify` 并关闭底层 TCP，重复调用安全 |
| 版本 | `TlsConn.get_version() -> str` | 固定返回 `TLSv1.3`（连接关闭后为空串） |

结果包装类：`TlsResult{ok,error,conn}`（`TlsConn{ssl,ctx,tcp,timeout_ms,alpn,...}`）。
`ssl`/`ctx` 为兼容旧 OpenSSL 实现保留的字段（`ssl` 复用为连接存活标记），新代码无需使用。

行为约定：

- **实现**：纯 RGC TLS 1.3（RFC 8446）客户端，密码学原语见 §6.17；不链接 OpenSSL 或其他密码库，编译时无需额外 `--link-args`。
- **协议范围**：仅 TLS 1.3；套件 `TLS_AES_128_GCM_SHA256` / `TLS_AES_256_GCM_SHA384` / `TLS_CHACHA20_POLY1305_SHA256`；组 x25519 与 secp256r1（ClientHello 同时携带两个 key share）；已处理 HelloRetryRequest 与 KeyUpdate，NewSessionTicket 忽略（无会话恢复）。
- **证书与签名**：服务端证书支持 RSA（PKCS#1 v1.5 / PSS）与 ECDSA P-256/P-384；CertificateVerify 按 RFC 8446 构造上下文（64×`0x20` + 标签 + `0x00` + Transcript-Hash），由 `lib/pkey.rg` 验签。
- **主机名校验**：`verify=True` 时用 `x509.hostname_matches` 校验 SAN（无 SAN 回退 CN）；DNS 名发送 SNI，IP 字面量不发 SNI。
- **CA 来源**：显式 `ca_file`（PEM，可含多个证书）优先；为空时用系统 CA 包（`SSL_CERT_FILE`，否则常见 bundle 路径，见 §6.18）。加载失败返回 `cannot load CA certificates`。
- **客户端证书（mTLS）**：`cert_file` 非空时按 PEM 读取证书链，`key_file`（为空复用 `cert_file`）读取私钥；失败返回 `cannot load client certificate` / `cannot load client private key`。支持 RSA 与 P-256 客户端密钥。
- **错误**：链/有效期错误来自 `x509.verify_chain`，主机名错误为 `certificate hostname mismatch for <host>`；记录层错误如 `bad record MAC or corrupted record` / `tls alert`；网络错误透传 `net` 的错误文本；全部通过 `ok=False` 表达，不 panic。
- **超时**：`timeout_ms` 用于 TCP 连接建立（`net.connect_to_timeout`）；握手与后续读写沿用流的阻塞语义，需要读写超时时用 `connect_on*` 传入已 `set_timeout` 的 `net.TcpStream`。
- **记录层**：单记录明文上限 16 KiB，自动分片；nonce = 静态 IV XOR 64 位序列号，AAD 为 5 字节记录头。
- **URL**：`https://host[:port][/path]`，默认端口 443；非 https URL 返回 `not an https URL (use the http module)`。
- **ALPN**：`connect_alpn` 提供 `h2`/`http/1.1`（`offer_h2=False` 仅提供 `http/1.1`），`TlsConn.get_alpn()` 返回服务端选择；`http` 用它决定走 HTTP/2 还是 HTTP/1.1（§11.6）。
- **连接复用/重定向/压缩/Cookie**：由 `http` 模块统一实现，见 §11.4。
- **未实现**：TLS 1.2 及以下、会话恢复/0-RTT、服务端实现、证书压缩、IPv6 证书地址匹配。

### 11.6 HTTP/2（`import http2`）

同步 HTTP/2 客户端（RFC 9113，TLS + ALPN `h2`）。常规请求无需直接使用本模块：
`http` 客户端会自动协商并调用它（§11.4）；需要自行管理连接或使用 HPACK/帧编解码时
直接 `import http2`。

```python
import http2

def main() {
    c = http2.connect("example.com", 443, 10000, True, "", "", "")
    if not c.ok {
        print("connect failed:", c.error)
        return
    }
    conn = c.conn
    hs = List[str]()
    hs.push("user-agent: rgc-demo")
    hs.push("accept: */*")
    r = http2.request(conn, "GET", "https", "example.com", "/", hs,
                      "", 0, False, 65536, 33554432)
    if r.ok {
        print(r.status, r.body.len)              # 200 <字节数>
        i = 0
        while i < r.headers.len() {
            print(r.headers.get(i))              # "content-type: text/html"
            i = i + 1
        }
    } else {
        print("request failed:", r.error)
    }

    # 单连接并发多路复用（仅 GET）：响应顺序与 paths 一致
    paths = List[str]()
    paths.push("/a")
    paths.push("/b")
    rs = http2.get_many(conn, "https", "example.com", paths, hs, 65536, 1048576)
    if rs.ok {
        i = 0
        while i < rs.responses.len() {
            one = rs.responses.get(i)
            print(i, one.ok, one.status, one.body.len)
            i = i + 1
        }
    }
    conn.close()
}
```

| API | 签名 | 说明 |
|-----|------|------|
| 连接 | `http2.connect(host, port, timeout_ms, verify, ca_file, cert_file, key_file) -> H2ConnectResult` | 新建 TCP + TLS（ALPN `h2`），发送 preface/SETTINGS 并等待服务端 SETTINGS；未协商到 `h2` 返回错误 |
| 接管 | `http2.attach(tc: TlsConn, host, port) -> H2ConnectResult` | 接管已完成 TLS 握手的连接（须 ALPN=`h2`），完成 HTTP/2 握手；失败时关闭底层连接 |
| 连接 | `http2.empty_conn() -> H2Conn` | 空连接对象（`closed=False`，不可直接请求），供字段初始化 |
| 请求 | `http2.request(c, method, scheme, authority, path, headers, body_ptr, body_len, has_body, max_header, max_body) -> H2Response` | 发送一个请求并读完响应；`headers` 为 `"name: value"` 行（不含伪头） |
| 多路复用 | `http2.get_many(c, scheme, authority, paths: List[str], headers: List[str], max_header, max_body) -> H2MultiResult` | 在单连接上并发发送多个 GET 并汇集响应；响应顺序与 `paths` 一致，遵守服务端 `MAX_CONCURRENT_STREAMS`，单流失败不影响其他流 |
| 编码 | `http2.encode_request_headers(method, scheme, authority, path, headers: @List[str]) -> Bytes` | HPACK 编码请求头（`:method`/`:scheme`/`:authority`/`:path` + 普通头） |
| 编码 | `http2.encode_response_headers(status, headers: @List[str]) -> Bytes` | HPACK 编码响应头（服务端方向） |
| 编码 | `http2.encode_trailers(headers: @List[str]) -> Bytes` | 编码 trailer 块（滤除伪头） |
| 解码 | `http2.new_decoder() -> H2Decoder` | 新建 HPACK 解码器（静态表 + 动态表，初始表大小 4096） |
| 解码 | `http2.decode_block(d: @var H2Decoder, block: @Bytes, max_size: int) -> H2HeaderList` | 解码一个完整头块；`max_size` 限制解码头总字节数 |
| 帧 | `http2.encode_frame(typ, flags, sid, payload: @Bytes) -> Bytes` | 生成 9 字节帧头（24 位长度 + 类型 + 标志 + 31 位流 ID）与载荷 |
| 关闭 | `H2Conn.close()` | 关闭底层 TLS/TCP；重复调用安全 |

结构（`H2Response.body` 为 `Bytes`，二进制安全）：

```python
public class H2ConnectResult {
    ok: bool
    error: str
    conn: H2Conn
}

public class H2Response {
    ok: bool
    error: str
    status: int
    headers: List[str]      # 响应头（"name: value" 行，不含伪头）
    trailers: List[str]     # DATA 之后的 trailer 行
    body: Bytes             # 响应正文
    conn_closed: bool       # 连接已不可复用（GOAWAY/EOF/错误）
}

public class H2MultiResult {
    ok: bool                # 传输层整体完成；单流失败只体现在对应 response.ok
    error: str
    responses: List[H2Response]   # 与请求 paths 同序
}
```

行为约定：

- **帧层**：支持 SETTINGS（含 INITIAL_WINDOW_SIZE / MAX_FRAME_SIZE /
  MAX_CONCURRENT_STREAMS）、PING 回显、
  WINDOW_UPDATE、GOAWAY、RST_STREAM、HEADERS/CONTINUATION、DATA（含 padding）与 trailer；
  未知帧类型按 RFC 忽略。
- **HPACK**：解码支持完整静态表（61 项）、动态表（含大小更新与逐出）与规范 Huffman 解码；
  编码使用无索引字面量 + 静态表名索引，不发 Huffman，也不维护编码端动态表。
- **流控**：连接与流窗口独立记账；发送端按 `min(连接窗口, 流窗口, MAX_FRAME_SIZE)` 切片，
  接收端每消费一个 DATA 帧即回 WINDOW_UPDATE，窗口上限截断到 2^31-1。
- **伪头与头过滤**：请求自动补四个伪头；编码时过滤 `connection`/`keep-alive`/
  `proxy-connection`/`transfer-encoding`/`upgrade` 等连接级头。响应/trailer 中出现伪头
  视为协议错误。
- **多路复用**：`get_many` 一次打开多个流（受服务端 `MAX_CONCURRENT_STREAMS` 约束，
  超出上限的请求排队），按流 ID 分发 HEADERS/DATA/trailer，并为每个流分别回
  WINDOW_UPDATE；`RST_STREAM`、单流正文超限只终止对应流，其余流继续读完。
  `request` 仍是单流顺序收发，便于发送请求体。
- **限制**：`get_many` 仅支持 GET（无请求体）；服务端推送关闭
  （`SETTINGS_ENABLE_PUSH=0`，收到 PUSH_PROMISE 拒绝）；仅 TLS ALPN，不支持 h2c
  明文升级与先验知识。
- **限额**：`max_header` 限制解码头块大小（`response header too large`），
  `max_body` 限制正文累计字节数（`response body too large`）；`0` 表示不限制。
- **错误**：连接/协议/流控错误通过 `ok=False` + `error` 返回，不 panic；
  `conn_closed=True` 时调用方不应再归还连接池。

### 11.7 后续扩展

| 能力 | 状态 | 说明 |
|------|------|------|
| TCP（客户端/服务端） | ✅ | `lib/net.rg` + 编译器 `tcp_*` 原语；`getaddrinfo` IPv4/IPv6、连接/收发超时、Unix 域、二进制收发 |
| UDP | ✅ | `lib/udp.rg`，`extern def` 调用 libc socket；IPv4/IPv6、数据报边界、收发超时、二进制载荷 |
| HTTP/HTTPS | ✅ | `lib/http.rg`：TLS（含 mTLS）、HTTP/2（ALPN）、重定向、keep-alive 池、gzip/deflate（含请求压缩）、trailer、Cookie、代理、限额、超时、二进制正文 |
| HTTPS/TLS 低层 | ✅ | `lib/tls.rg`（纯 RGC TLS 1.3，含客户端证书与 ALPN）+ `lib/https.rg` 兼容层，无外部密码库依赖 |
| HTTP/2 | ✅ | `lib/http2.rg`：帧层、HPACK（静态/动态/Huffman 解码）、流控、trailer、GOAWAY/RST_STREAM、`get_many` 并发多路复用（GET）、无服务端推送、无 h2c |
| 压缩 | ✅ | `lib/gzip.rg`：纯 RGC DEFLATE（stored/fixed/dynamic Huffman、LZ77 fixed-Huffman 压缩、CRC-32/Adler-32、多 member gzip），`compress`/`decompress`/`decompress_limit`/`decompress_mem`/`is_gzip`/`is_zlib`；文件级 `compress_to_file`/`decompress_file`/`decompress_file_limit`（二进制安全，含 NUL 数据） |
| 归档 | ✅ | `lib/tar.rg`：纯 RGC tar 读写，读 ustar / GNU LongLink / PAX（`path`/`linkpath`/`size`/`mtime`），写 ustar + 长名 GNU LongLink；`list_entries`/`extract`/`create`/`builder`；与 gzip 文件 API 组合处理 `.tar.gz`（§6.16） |
| 异步 HTTP | ✅ | `get_async`/`post_async`/`request_async`（一任务一线程），支持 `asyncio.gather` |
| 事件循环 | ✅ | `lib/event.rg`：poll selector、单调时钟定时器、回环 UDP 跨线程唤醒（§10.5） |
| 非阻塞 TCP/UDP | ✅ | `net`/`udp` 的 `set_nonblocking`、`try_*`、`connect_start`/`connect_finish` |
| 异步 TCP/UDP | ✅ | `net_async`：poll（`event.wait_fd`）+ 非阻塞 socket，`await` 友好，支持总超时/取消；线程模型仍为一任务一线程 |
| HTTP/2 多路复用 | ✅ | `http2.get_many`：单连接并发 GET、按流分发、逐流限额/取消、遵守 `MAX_CONCURRENT_STREAMS`；请求体仍走单流 `request` |

> 测试：`tests/stdlib/net/`（回环 echo、EOF、错误路径）、`tests/stdlib/net_unix/`
> （Unix 域回环、残留 socket 文件清理、路径长度错误）、`tests/stdlib/http/`
> （测试进程自举 `--serve` 子进程，覆盖 GET/POST/chunked/trailer/keep-alive/重定向/
> Cookie/gzip/deflate/请求压缩/限额/超时/1xx/HEAD/204/二进制/查询编码/代理/异步 gather）、
> `tests/stdlib/udp/`（回环收发、数据报边界、IPv6、二进制、非阻塞收发、超时、截断、错误路径）、
> `tests/stdlib/event/`（定时器、post 唤醒、极简 TCP/UDP 事件驱动、关闭/错误路径）、
> `tests/stdlib/gzip/`（gzip/zlib/raw deflate、多 member、压缩往返、level 0/9、格式识别、损坏输入、输出上限）、
> `tests/gzip_interop/suite.rg`（`rack test` 运行；与系统 gzip/gunzip 互操作，fixture 以纯 RGC 构造：FEXTRA/FNAME/FCOMMENT/FHCRC、stored/dynamic 块、
> 多 member、zlib/raw、尾随垃圾、CRC/Adler 失败、FDICT）、
> `tests/stdlib/bytes_io/`（二进制读写含 NUL、空文件、覆盖截断、缺失路径、gzip 文件 API 与限额）、
> `tests/stdlib/tar/`（打包/列表/提取、目录、长名、mtime/mode、坏校验和/截断、空名与非法 kind）、
> `tests/tar_interop/suite.rg`（与系统 GNU tar 双向互操作：ustar prefix、GNU LongLink、PAX path、
> symlink、空文件、二进制载荷、`.tar.gz`，RGC 产物可被 Python 直接读取）、
> `tests/stdlib/http2/`（RFC 9113 Huffman/HPACK 静态表、动态表与索引、请求/响应/trailer 编码、
> 帧头、截断与限额错误）、`tests/tls/suite.rg`（openssl s_server + 自签名证书，覆盖 http/https
> 校验成功与失败、`get_insecure`、低层 `tls.connect` 与 mTLS 客户端证书）与
> `tests/http2/suite.rg`（nghttpd + 自签名证书，覆盖 ALPN、HPACK Huffman 响应头、小窗口流控、
> 大正文 GET/POST、trailer、重定向、404、CA 校验、HttpClient 集成与并发多路复用
> （`-m 2` 排队、404、空列表、单流超限隔离））。

### 11.8 异步网络（`import net_async`）

`lib/net_async.rg` 在 `net`/`udp` 的非阻塞原语之上，用 `event.wait_fd`（poll）
等待 fd 就绪，提供 `await` 友好的 TCP/UDP API。等待按 50 ms 切片，因此 `timeout_ms`
是总超时，并在切片之间轮询 `asyncio.cancelled()`；`await` 会把父任务的取消转发给
正在等待的子任务（§10.4）。任务仍是一任务一线程，事件循环只负责 fd 就绪。

| API | 签名 | 说明 |
|-----|------|------|
| TCP 连接 | `connect_to(host: str, port: int, timeout_ms: int) -> TcpConnect` | 非阻塞 connect + `ev_out` 等待；返回 `TcpStream` |
| TCP 接受 | `accept(listener_fd: int, timeout_ms: int) -> TcpAccept` | 监听 fd 需为非阻塞；返回 `TcpAccept` |
| TCP 收 | `recv(fd: int, max: int, timeout_ms: int) -> TcpRecv` | 文本；对端关闭返回 `ok=True` + 空串 |
| TCP 收 | `recv_bytes(fd: int, max: int, timeout_ms: int) -> TcpRecvBytes` | 二进制安全；返回 `Bytes` |
| TCP 发 | `send(fd: int, data: str, timeout_ms: int) -> TcpSend` | 循环写满全部字节，`EAGAIN` 时等 `ev_out` |
| UDP 收 | `udp_recv(fd: int, max: int, timeout_ms: int) -> UdpRecv` | 保留数据报边界 |
| UDP 发 | `udp_send(fd, family, data, host, port, timeout_ms) -> UdpSend` | `family` 传 `sock.family`（IPv4 为 `2`） |
| 取消探测 | `is_cancelled() -> bool` | 当前任务是否收到取消请求（供自定义等待循环使用） |

行为约定：

- `timeout_ms < 0` 无限等待，`0` 只轮询一次；超时/取消分别返回 `error="timeout"` / `"cancelled"`。
- 这些函数把传入的 fd 设为非阻塞；API 接收 `fd: int` 而不是 socket 对象，避免把流移进任务。
- TCP `send` 直到全部字节写完才返回；`sent` 为实际写入字节数。`recv` 每次最多 `max` 字节。
- 只覆盖 TCP/UDP；TLS/HTTP 的异步流式封装仍待后续（高并发 HTTP 可用 `get_async` + 线程）。

```python
import net, net_async, asyncio

async def client(port: int) -> str {
    c = await net_async.connect_to("127.0.0.1", port, 1000)
    if not c.ok { return "connect:" + c.error }
    s = c.stream
    await net_async.send(s.fd, "ping", 1000)
    r = await net_async.recv(s.fd, 64, 1000)
    s.close()
    return r.value
}
```

> 测试：`tests/stdlib/net_async/`（TCP echo + gather、读超时、嵌套 await 取消、
> UDP 回环、连接拒绝）。

---

## 12. 与 Python / Rust 对照

### 12.1 核心

| RGC | Python | Rust | 说明 |
|-----|--------|------|------|
| `Maybe[T]` | 可选值（无内建） | `Option<T>` | 模式匹配推荐 |
| `Result[T, E]` | 异常 | `Result<T, E>` | 可恢复错误 |
| `List[T].push` | `list.append` | `Vec::push` | — |
| `list.pop` | `list.pop()` | `Vec::pop` | — |
| `io.read_file` | `open().read()` | `std::fs::read_to_string` | 返回 Result |
| `print` | `print()` | `println!` | 已实现 |
| 错误处理 | `try/except` | `?` 运算符 | RGC 用 `?` 传播 + `match` 处理 |

### 12.2 远期模块

| 类别 | Python | Rust | RGC |
|------|--------|------|-----|
| 时间 | `time` / `datetime` | `std::time` | `time`（✅ §6.9） |
| 随机 | `random` | `rand` crate | `random`（✅ §6.10） |
| JSON | `json` | `serde_json` | `json`（✅ §6.11） |
| 系统/进程 | `os` / `subprocess` | `std::env` / `std::process` | `os`（✅ §6.12，`system` 已内建） |
| 命令行参数 | `sys.argv` | `std::env::args` | `args`（✅ §6.13） |
| 正则 | `re` | `regex` crate | `regex`（✅ §6.14） |
| 异步 | `asyncio` | `tokio` / `async-std` | `asyncio`（✅ 一任务一线程，`gather` / `wait_any` / `wait` / `cancel`，§10） |
| 网络 | `socket` / `urllib` / `http.client` / `httpx` | `std::net` / `reqwest` / `hyper` | `net` / `udp` / `http` / `http2` / `https` / `tls` / `gzip`（✅ 同步 TCP/UDP/HTTP/1.1/HTTP/2、HTTP/2 多路复用 + 重定向/keep-alive/Cookie/代理，§11） |
| 并发 | `threading` | `std::thread` | `async` 一任务一线程（✅ `gather` / `wait_any` / `Task.done` / `Task.wait` / `Task.cancel`，§10）+ `event` poll 事件循环（✅ §10.5） |

---

## 13. 实现状态与优先级

### 13.1 当前目标（标准库第一批）

按依赖排序：

1. ✅ **`to_string` + `str` 方法**（`len` / `+` / `contains` / `startswith` / `endswith` / `char_at` / `slice` / `split` / `join` / `to_int`）— 编译器内建
2. ✅ **`List[T]`**（`len` / `push` / `pop` / `get` / `set` / `contains` / 迭代）— 编译器内建
3. ✅ **`Maybe[T]` / `Result[T, E]` 方法**（`is_*` / `unwrap` / `expect`）— 编译器内建泛型枚举
4. ✅ **`args()` 命令行参数** — CLI 工具的必需品
5. ✅ **`io.read_file` / `write_file`** — 内建 libc 调用，返回 `Result`
6. ✅ **模块系统 `import` / `public` 完善** — 已具备基础能力（见测试 `modules/`）
7. ✅ **`cat` 克隆示例** — 里程碑验收（`examples/cat.rg`）
8. ✅ **`Map[K, V]`**（`len` / `contains` / `get` / `put`）— 符号表可用
9. ✅ **位运算** `& | ^ << >>` — 语言级支持
10. ✅ **`system(cmd)`** — 进程调用（libc `system` + WEXITSTATUS）
11. ✅ **`str.to_float`** — `strtod` + 完整消费校验（尾随字符返回 Err）
12. ✅ **`List.clear`** — 保留容量、长度归零
13. ✅ **`io.append_file` / `io.exists` / `io.remove_file`** — 文件 IO 扩展，删除失败返回 Err
14. ✅ **`format(fmt, args...)`** — 字面量格式串 + `{}` 占位符（int/float/bool/str）
15. ✅ **`math` 内建**（`abs`/`min`/`max`/`sqrt`/`pow`/`floor`/`ceil`）— LLVM intrinsic + 比较/select，零运行时库依赖（`math.*` 与无前缀两种调用形式）
16. ✅ **`time` 内建模块**（`now_monotonic`/`now`/`sleep`）— libc `clock_gettime`/`time`/`nanosleep`
17. ✅ **`random` 内建模块**（`seed`/`random_int`/`random_float`）— 编译器生成的 xorshift64 全局状态
18. ✅ **`os` 内建模块**（`exit`/`getenv`/`setenv`/`getcwd`/`system`）— libc 直接调用
19. ✅ **`Result` 错误传播 `?`** — 语言级后缀运算符：`Err` 提前返回同错误类型，成功取载荷
20. ✅ **`range(start, end[, step])`** — 1–3 参数，负步长递减，步长 0 不迭代
21. ✅ **`json` 源码模块**（`parse`/`stringify` + 构造/访问/修改 API）— `lib/json.rg`，支持 `\uXXXX`（含代理对）、`\b`/`\f`、控制字符校验、深度上限、i64 范围校验与非有限浮点降级
22. ✅ **`regex` 源码模块**（`compile`/`is_match`/`find`/`search`/`replace`）— `lib/regex.rg`，回溯引擎，支持捕获组/非捕获组、反向引用 `\1`–`\99`、贪婪与惰性量词、`{m,n}`、`\b`/`\B` 及替换组引用
23. ✅ **`net` 同步 TCP 完善**（`connect_timeout`/`connect_to_timeout`/`resolve`/`connect_unix`/`listen_unix` + `TcpStream`/`TcpListener`）— `getaddrinfo` IPv4/IPv6、连接与收发超时、Unix 域、`send_bytes`/`recv_bytes` 二进制收发、半关闭与 peer/local 地址
24. ✅ **`udp` 同步 UDP**（`open`/`open_on` + `UdpSocket`）— `lib/udp.rg`，`extern def` 调用 libc socket，IPv4/IPv6/主机名、数据报边界、收发超时、`send_bytes`/`data_bytes` 二进制载荷与截断
25. ✅ **`http` HTTP 客户端**（`get`/`post`/`request`/`*_with`/`request_bytes` + `HttpClient`）— `lib/http.rg`：原生 HTTPS、HTTP/2 协商、keep-alive 连接池、重定向、Cookie、HTTP 代理与 CONNECT 隧道、gzip/deflate、请求体压缩、trailer 暴露、1xx 跳过、正文/头限额、连接/读超时、二进制正文与查询串编解码
26. ✅ **`https`/`tls` 客户端**（`https.get`/`post`/`get_insecure` + `tls.connect`/`TlsConn`）— `lib/tls.rg` + `lib/https.rg`，纯 RGC TLS 1.3：校验证书链/主机名/IP、SNI，客户端证书（mTLS）；`https` 为 `http` 的兼容层（详见第 38 条与 §11.5）
27. ✅ **`chr(cp)` 内建** — Unicode 码点 → UTF-8 字符串（1–4 字节），非法码点 panic 退出
28. ✅ **异步编程**（`async def` / `await` / `asyncio.run` / `asyncio.gather` / `asyncio.wait_any` + `Task[T]`）— 编译器生成 pthread 派生/join，载荷支持标量、`str` 与自定义类；`Task.done` / `Task.wait` 提供完成查询与超时等待；`asyncio.wait_any` 返回首个完成任务下标且不消费任务；`Task.cancel` / `asyncio.cancelled` 提供协作式取消；事件循环见下条与 §10.5
29. ✅ **`gzip` 源码模块**（`compress`/`decompress`/`decompress_limit`/`decompress_mem`/`is_gzip`/`is_zlib`）— 纯 RGC DEFLATE（无 zlib 依赖）：stored/fixed/dynamic Huffman 解压、LZ77 + fixed-Huffman 压缩、CRC-32/ISIZE 与 Adler-32 校验、多 member gzip、`decompress_limit` 限制输出字节数（防解压炸弹）
30. ✅ **`https`/`http` 统一** — `http.parse_url` 与请求路径原生处理 `https://`（TLS 握手 + 证书校验），`https` 模块保留为不校验开关的兼容层
31. ✅ **异步 HTTP 封装**（`http.get_async`/`post_async`/`request_async`）— 一任务一线程包装阻塞客户端，可与 `asyncio.gather` 并发；事件驱动版本待事件循环封装
32. ✅ **协议完整性收口** — HTTP chunked trailer 暴露（`HttpResponse.trailers` / `http.trailer`）、请求体 gzip 压缩（`HttpClient.compress_request`）、TLS 客户端证书（`tls.connect_mtls` / `connect_on_mtls`、`HttpClient.set_client_cert`）与 gzip 多 member/压缩
33. ✅ **`http2` HTTP/2 客户端**（`http2.connect`/`attach`/`request`/`get_many` + HPACK/帧 API）— `lib/http2.rg`：TLS ALPN `h2`、SETTINGS/PING/WINDOW_UPDATE/GOAWAY/RST_STREAM、HEADERS/CONTINUATION/DATA、trailer、HPACK 静态/动态表与 Huffman 解码、连接与流双流控；`http`/`HttpClient` 默认自动协商（`http2` 字段可关闭）；`get_many` 单连接并发多路复用 GET
34. ✅ **`event` 事件循环**（`new_loop`/`add`/`modify`/`remove`/`wait`/`add_timer`/`add_interval`/`post`）— `lib/event.rg`：poll + 单调时钟截止时间 + 回环 UDP 唤醒；配套 `net`/`udp` 非阻塞原语（`connect_start`/`try_*`/`set_nonblocking`），不依赖闭包与函数指针
35. ✅ **`bytes` 源码模块**（`bytes_new`/`bytes_from_str`/`bytes_from_mem`/`bytes_concat`/`read_bytes`/`write_bytes` + `Bytes` 方法）— `lib/bytes.rg`：二进制缓冲区与二进制安全文件读写；`io.*` 为 C 字符串语义（遇 NUL 截断），压缩包/归档等必须走 `bytes`
36. ✅ **gzip 文件 API**（`compress_to_file`/`decompress_file`/`decompress_file_limit`）— 在 `lib/gzip.rg` 内基于 `bytes.read_bytes`/`write_bytes` 封装，直接读写 `.gz` 文件
37. ✅ **`tar` 源码模块**（`list_entries`/`extract`/`create`/`builder`/`create_from`）— `lib/tar.rg`：纯 RGC tar 读写，读 ustar/GNU LongLink/PAX，写 ustar + 长名 GNU LongLink，目录与二进制文件，配合 gzip 处理 `.tar.gz`
38. ✅ **纯 RGC TLS 1.3 与密码学栈**（移除 OpenSSL）— `lib/tls.rg` 以纯 RGC 实现握手、密钥调度、记录层与证书校验，依赖新增的 `lib/sha2.rg`、`lib/hmac.rg`、`lib/hkdf.rg`、`lib/aes.rg`（AES-GCM）、`lib/chacha20poly1305.rg`、`lib/x25519.rg`、`lib/p256.rg`（P-256/P-384）、`lib/rsa.rg`、`lib/bigint.rg`、`lib/asn1.rg`、`lib/pkey.rg`、`lib/x509.rg`、`lib/entropy.rg`；编译器不再自动追加 `-lssl -lcrypto`；互操作测试覆盖 AES-128/256-GCM、ChaCha20-Poly1305、P-256 组、RSA/ECDSA 证书、ALPN、SNI、mTLS 与主机名不匹配（`tests/tls/suite.rg`），密码学向量见 `tests/stdlib/crypto/`（§6.17/§6.18）
39. ✅ **`List` 扩展** — `insert`/`remove`/`remove_at`/`index_of`/`reverse`，越界钳制与空表零值语义；用例见 `tests/stdlib/collections_extra/`
40. ✅ **`str` 扩展** — `find`/`rfind`/`trim`/`trim_start`/`trim_end`/`replace`/`repeat`/`lines`，按字节语义；用例见 `tests/stdlib/str_extra/`
41. ✅ **`Map` 哈希化 + 扩展** — 开放寻址哈希表（线性探测、墓碑删除、0.75 负载因子、字符串 FNV-1a / 数值 splitmix64），新增 `remove`/`keys`/`values`；API 不变。编译器自身符号表同步受益：自编译 `--emit-llvm` 由约 2.37s 降至 1.64s（约 30%）；用例见 `tests/stdlib/map_extra/`
42. ✅ **内建方法参数检查** — List/Map/str/Maybe/Result/Task 方法的实参个数与类型在编译期校验（如 `List[int].push("x")`、`str.repeat("x")`、`Map[str,int].put("a","b")` 均报错），负例见 `tests/stdlib/negative/`
43. ✅ **异步网络接入事件循环** — `event.wait_fd` 单次 poll 就绪等待 + `lib/net_async.rg`：非阻塞 TCP/UDP、总超时、协作式取消；`await` 在任务线程内轮询父任务取消并转发给正在等待的子任务。仍为一任务一线程（事件循环负责 fd 就绪，不是协程调度）；用例见 `tests/stdlib/net_async/`

> **测试位置**：上述 stage1 特性用例在 `tests/stdlib/`（由 `rack test` 运行并校验输出；`os.exit` 用例通过 `exit` 文件声明预期退出码）。
> 这些用例刻意不放入 `examples/`，让 `examples/` 只保留最小可运行示例。

> **自举路线**：以上能力（str 字符访问/解析、动态数组、映射、进程调用、位运算）已覆盖编写编译器前端（lexer/parser）所需的核心语言能力；下一步可用 RGC 编写 lexer + parser 验证表达力，再逐步迁移后端。

> **技术决策**：`to_string` / `str` 方法 / `List` / `Maybe` / `Result` 以**编译器内建**形式实现（`str` 是内建类型，`List` 需要堆分配与指针布局，`Maybe`/`Result` 的 `unwrap`/`expect` 需要 panic+`exit` 行为，当前语言尚无指针/析构/异常能力，无法用 RGC 自身表达）。`json` / `regex` / `string` / `list` / `path` 则用 RGC 自身写成 `lib/` 源码模块，经 `import` 由标准库搜索路径加载。后续引入 FFI 与析构后，可评估是否把更多内建迁移为源码模块。
> **已知限制**：运行时堆分配（字符串拼接、`to_string`、`List` 缓冲区）暂不自动释放，进程退出时由 OS 回收。

### 13.2 Phase 10+（依赖 FFI / 后端）

`time` / `random` / `math` / `os` 已通过 **libc 调用 + LLVM intrinsic** 提前落地，无需通用 FFI。剩余：

1. **FFI 基础**（用户态调用任意 C 库）— 生态包与系统库接入的前置（TLS 已改为纯 RGC，不再依赖它）
2. ✅ **同步网络**（`TcpStream` / `TcpListener`，libc socket）— 已实现，见 §11
3. ✅ **异步/协程**（`async def` / `await` / `asyncio.run` / `asyncio.gather` / `asyncio.wait_any` / `Task.done` / `Task.wait` / `Task.cancel`）— 已实现一任务一线程（见 §10）；取消为协作式（`asyncio.cancelled` 轮询）；poll 事件循环由 `lib/event.rg` 独立提供（§10.5）
4. ✅ **UDP / TLS**（`lib/udp.rg`、`lib/tls.rg`/`lib/https.rg`）— UDP 走 `extern def` + libc；TLS 为纯 RGC TLS 1.3（无外部密码库），已落地，见 §11.3/§11.5
5. ✅ **HTTP/2**（`lib/http2.rg`）— TLS ALPN + 帧层 + HPACK + 流控，`http` 默认协商；已落地，见 §11.6；`get_many` 提供并发多路复用（GET，不依赖事件循环）
6. ✅ **事件循环**（`lib/event.rg`）— poll + 单调时钟截止时间 + 回环 UDP 唤醒，配套 `net`/`udp` 非阻塞原语与 `event.wait_fd` 单次等待；`net_async` 把 `await` 与非阻塞 TCP/UDP 接到 poll 就绪上（§11.8），仍为一任务一线程

> `json` 与 `regex` 已作为 `lib/` 源码模块落地；`json` 的转义、代理对、控制字符校验与深度限制已完成，`regex` 的捕获组、反向引用、惰性量词与替换组引用已完成。`regex` 仍按字节匹配，Unicode 字符类、lookaround 与命名组暂不支持。

---

## 14. 尚未决定的问题（需要评审）

- [ ] `str.len()` 按字节还是按字符？
- [ ] 越界索引：abort 还是返回 `Result`？
- [ ] 错误信息类型：`str` 还是结构化错误类型？
- [x] `?` 运算符是否进入 Phase 8？— 已实现：限 `Result` / 同错误类型，成功载荷暂限标量
- [x] 标准库是内建函数集合还是真模块（`import`）？— 混合：核心内建 + `lib/` 源码模块（json/regex/string/list/path）
- [ ] 泛型方法（如 `map`）需要函数值支持，是否提前到 Phase 9？
- [x] 异步：先「同步 IO + 线程池」（Rust std 风格）还是直接 `async/await`？— 已实现：`async def` / `await` / `asyncio.run` / `asyncio.gather` / `asyncio.wait_any` / `Task.done` / `Task.wait` / `Task.cancel`，一任务一线程（§10）
- [x] 网络地址类型：`str`（`"host:port"`）还是结构化 `Addr` 类型？— 已实现 `str` 形式（按最后一个 `:` 切分），另提供 `(host, port)` 重载式函数 `connect_to`/`listen_on`
- [x] HTTP 客户端进标准库还是留给生态包？— 进标准库（`lib/http.rg`），并补齐重定向、keep-alive 连接池、gzip/deflate、请求体压缩、trailer、Cookie、代理、限额与超时；HTTP/2 由 `lib/http2.rg` 实现并默认经 ALPN 协商（§11.6）
- [x] HTTP trailer / 请求压缩 / 客户端证书是否纳入？— 纳入：trailer 存入 `HttpResponse.trailers` 并提供 `http.trailer`；请求压缩由 `HttpClient.compress_request` 控制（gzip）；mTLS 由 `HttpClient.client_cert`/`client_key` 与 `tls.connect_mtls` 提供
- [x] HTTPS/TLS 是否纳入标准库，还是靠 FFI 生态？— 已纳入：`lib/tls.rg` + `lib/https.rg` 以纯 RGC 实现 TLS 1.3（无外部密码库），证书/ASN.1 栈见 §6.17/§6.18
- [x] `http` 与 `https` 是否合并？— 请求路径统一走 `http`（原生 `https://`），`https` 保留为兼容层，避免两套连接/重定向/压缩实现漂移
- [x] 压缩依赖是否引入第三方库？— 不引入：`lib/gzip.rg` 为纯 RGC DEFLATE + CRC-32/Adler-32 实现，链接期不再追加 `-lz`；与系统 gzip/gunzip 的互操作由 `tests/gzip_interop/suite.rg`（`rack test`）校验
- [x] 并发模型：线程（Rust 风格）还是协程（Python/Go 风格）？— `async` 用 pthread 一任务一线程；另提供 `lib/event.rg` poll 事件循环（§10.5），协程调度暂不实现
- [x] 格式化：采用 `format(fmt, args...)`（方案 2）；f-string 推迟到语法扩展阶段
- [x] `format` 是否扩展格式说明符（宽度/精度/进制）与 `{{` / `}}` 转义？— 已实现宽度/精度/进制/对齐/补零与转义（§7）；位置参数与动态宽度暂不支持

---

> 本文档是 API 契约，不是实现。每个 API 落实现后，将状态标记从 🚧/⏳ 改为 ✅，并补充行为细节与测试链接。