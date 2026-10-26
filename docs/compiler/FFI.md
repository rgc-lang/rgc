# FFI 与 pyrgc —— C 互操作与 Python 绑定

> 状态：v0.4（`export def` 宿主导出标记 + vectorcall 胶水 + str 所有权）
> 组成：编译器 `extern def`（C ABI 外部函数声明）、`export def`（宿主运行时导出标记）与 `--emit-exports`（签名/所有权元数据），外加 `pyrgc` 官方 Python 绑定框架（CPython C API）

---

## 1. extern def：调用 C 函数

`extern def` 声明一个 C ABI 的外部函数（无函数体），符号由链接器在链接期解析：

```python
# 直接调用 libc
extern def puts(s: str) -> int
extern def abs(x: int) -> int
extern def atof(s: str) -> float
extern def isdigit(c: int) -> bool

def main() {
    puts("hello from libc")
    print(abs(-42))
    print(atof("2.5") * 4.0)
    print(isdigit(55))       # '7'
}
```

约束：

- `extern def` 只能是声明，没有函数体；不能是泛型。
- 参数/返回类型限定 `int` / `float` / `bool` / `str`（自定义类型、借用类型不支持）。
- 符号保持裸名，不做模块改名（`module$name`）；在 stdlib 模块中声明的 extern 同样是全局符号。
- 调用 C 函数所需的库用 `--link-args` 传入，例如 `rgc demo.rg --link-args "-lsqlite3"`（libc/libm 默认已链接）。

### 1.1 类型映射（RGC ↔ C）

| RGC | C 参数 | C 返回值 | 说明 |
|-----|--------|----------|------|
| `int` | `long long` (i64) | `int` (i32) | 返回值调用点自动 `sext` 回 64 位；C `int` 参数取低 32 位 |
| `float` | `double` | `double` | |
| `bool` | `_Bool` (i8) | `int` (i32) | 返回值按 C 真值语义（非零即真）转换 |
| `str` | `const char*` | `const char*` | NUL 结尾 C 字符串指针 |
| `None` | — | `void` | |

注意：返回 `int` 的映射对应 C `int`（32 位）。需要 64 位返回值的 C 函数
（如 `labs`/`strtoll`）声明为 `-> int` 时只保留低 32 位并符号扩展，
超出 `int` 范围的返回值需自行包装。

### 1.2 编译器新增 CLI 标志

| 标志 | 作用 |
|------|------|
| `--emit-object` | 只生成目标文件（`.o`），不链接（pyrgc 构建流程使用） |
| `--shared` | 链接为共享库（Unix：`g++ -shared -fPIC`；Windows：`g++ -shared`，函数带 LLVM `dllexport`），供 pyrgc / 插件场景使用 |
| `--emit-exports <json>` | 额外写出入口文件全部顶层函数的签名、`export` 标记与 `str` 返回值所有权分类（绑定生成器使用） |

RGC 输出的目标文件是 PIC（位置无关），可直接参与共享库链接。

Windows 上 `--shared` 会给编译单元内定义的函数加 LLVM `dllexport`，COFF 目标的
`.drectve` 段因此带上 `/EXPORT` 指令，由链接器写入 DLL 导出表；可执行文件则直接
链接 `ws2_32`（Winsock）与 `bcrypt`（`BCryptGenRandom`，见 `entropy`）。

`--emit-exports` 的 JSON 在语义检查通过后、IR 生成之前写出，因此它与
`--emit-llvm` 可以同时使用，也不受后端崩溃影响：

```json
{"format": 2, "source": "examples/pyrgc_demo.rg",
 "functions": [{"name": "greet", "public": false, "export": true,
                "params": [{"name": "name", "type": "str"}],
                "ret": "str", "str_ret": "owned"}]}
```

签名与导出标记都由编译器发布，而不是让绑定生成器用正则去刮源码：类型解析、默认值、
`@`/`@var` 借用前缀都只有编译器知道，两边各写一份解析器必然失同步。

### 1.3 export def：把函数交给宿主运行时

`export` 是声明修饰符（上下文关键字，不是保留字），标出宿主运行时的绑定生成器
可以包装的函数：

```python
export def add(a: int, b: int) -> int {
    return a + b
}

public export def greet(name: str) -> str {
    return "hello, " + name + "!"
}
```

- `export` 与 `public` 正交：`public` 是 RGC 模块之间的可见性，`export` 是宿主
  运行时的可见性，两者各自独立、也可同时出现。这正是 PyO3 里 `pub fn` 与
  `#[pyfunction]` 的分工——只有带标记的函数才会被包装给 Python。
- 标记由编译器理解，并作为 `"export": true/false` 写进 `--emit-exports` 元数据；
  绑定生成器只读元数据，不扫描源码，也就不存在“标记写法变了、扫描器没跟上”。
- 它只影响元数据，不改变生成代码：没有宿主运行时消费时，`export def` 与
  `def` 生成的程序完全一致。RGC 标准库因此不需要任何 pyrgc 运行时模块。
- 导出名即 RGC 函数名。

### 1.4 字符串拼接的临时缓冲区

`str` 是裸 `malloc` 缓冲区且 RGC 无 GC，链式 `a + b + c` 会为每个 `+`
分配一个缓冲区，但只有最外层的那个会逃逸出表达式。代码生成在字节拷贝完成后
立即释放嵌套的中间缓冲区（它们是刚 malloc 出来的一次性临时值，没有任何
其他引用），因此链长不再影响常驻内存：1/2/4 段链的峰值 RSS 修复前为
7.3/13.6/26.1 MB，修复后同为 7.4 MB 基线。最外层缓冲区仍然由调用方
（pyrgc 胶水或 RGC 变量作用域）负责。

---

## 2. pyrgc：Python 绑定框架

`pyrgc` 是 RGC 的官方 Python 绑定框架，定位对齐 pybind11 / PyO3：
把 RGC 函数导出为 **CPython 扩展模块**，Python 侧直接 `import`。
实现直接走 **CPython C API**：pyrgc 构建器先用
`rgc --emit-object --emit-exports` 编译 RGC 代码并取回函数元数据，
再为每个导出函数生成 **`METH_FASTCALL`（vectorcall）** C 胶水——
显式参数个数检查 + 逐个参数类型提取 + 返回值构造 +
`PyMethodDef` 方法表 + `PyInit_<module>` 模块入口，
最后链接为 `.so`（不依赖 libpython，符号由解释器在 import 时解析——与 CPython
官方扩展构建方式一致）。

胶水走 vectorcall 而不是 `METH_VARARGS` + `PyArg_ParseTuple`：后者要为每次调用
先建一个 tuple、再解析格式串。改为直接对 `PyObject *const *args` 调用
`PyLong_AsLongLong` / `PyFloat_AsDouble` / `PyObject_IsTrue`（即 `"L"`/`"d"`/`"p"`
格式内部使用的同一批函数），接受的输入、溢出行为与异常类型完全不变，
而 tuple 构造与格式串解析消失。

### 2.1 RGC 侧

```python
# examples/pyrgc_demo.rg — export def 标出要包装给 Python 的函数
export def add(a: int, b: int) -> int {
    return a + b
}

export def greet(name: str) -> str {
    return "hello, " + name + "!"
}

export def is_even(n: int) -> bool {
    return n % 2 == 0
}
```

- 导出函数必须写在**入口文件**且带**显式类型注解**（胶水需要 C 签名）。
- `export` 是编译器理解的声明修饰符（见 §1.3），pyrgc 只消费
  `--emit-exports` 元数据里的 `"export": true` 函数；签名与类型同样来自元数据，
  两边不重复解析源码。
- `export` 不引入任何运行时依赖：RGC 标准库里没有 pyrgc 模块，
  `import pyrgc` 这类为标记而存在的空函数也不存在。
- 支持的导出类型：`int` / `float` / `bool` / `str` / `None`。

### 2.2 安装、构建与使用

pyrgc 以标准 Python 包分发（参考 PyO3/maturin 的模式，`pyrgc/pyproject.toml`）：

```bash
pip install -e pyrgc/                 # 或 PYTHONPATH=pyrgc python3 -m pyrgc
```

maturin 风格工作流：

```bash
pyrgc new string_sum                  # 脚手架：string_sum.rg + pyproject.toml
cd string_sum && pyrgc build          # -> dist/string_sum.<ext-suffix>.so
pyrgc develop                         # 构建并安装到激活的 virtualenv
```

直接构建（仓库根目录）：

```bash
pyrgc build examples/pyrgc_demo.rg -n pyrgc_demo -o build/pyrgc
#   built: build/pyrgc/pyrgc_demo.cpython-313-x86_64-linux-gnu.so (5 exports: add, greet, is_even, dist, say_hi)

python3 -c "
import sys; sys.path.insert(0, 'build/pyrgc')
import pyrgc_demo
print(pyrgc_demo.add(3, 4))        # 7
print(pyrgc_demo.greet('rgc'))     # hello, rgc!
print(pyrgc_demo.is_even(10))      # True
print(pyrgc_demo.add.__doc__)      # 函数上方 # 注释成为 __doc__（对齐 PyO3 doc comment）
"
```

`build` 选项：`-n` 模块名（默认文件名）、`-o` 输出目录、`--rgc` 编译器路径
（默认 `RGC` env / `PATH` / 仓库 `build/rgc`）、`--cc` C 编译器（默认 `cc`）、
`--debug` 关闭优化（`rgc -O0`）。项目内 `pyrgc build` 自动向上发现
`pyproject.toml` 的 `[tool.pyrgc]` 段（`name`/`source`/`out-dir`/`rgc`/`cc`/`release`/`link-args`）。

### 2.3 类型映射（RGC ↔ CPython）

| RGC | Python | 参数提取 | 返回值构造 |
|-----|--------|----------|------------|
| `int` | `int` | `PyLong_AsLongLong`（接受 `__index__`） | `PyLong_FromLongLong` |
| `float` | `float` | `PyFloat_AsDouble`（接受 `__float__`） | `PyFloat_FromDouble` |
| `bool` | `bool` | `PyObject_IsTrue` | `PyBool_FromLong` |
| `str` | `str` | `PyUnicode_Check` + `PyUnicode_AsUTF8AndSize` | `PyUnicode_FromString`（owned 时再 `free`） |
| `None` | `None` | — | `Py_RETURN_NONE` |

参数个数不符时由胶水抛出 `TypeError`（`f() takes exactly N arguments (M given)`）；
类型不符时沿用 `PyArg_ParseTuple` 的措辞（含 CPython 把 `None` 打印成 `None`
而非 `NoneType` 的特例）。`str` 参数遇到内嵌 NUL 抛 `ValueError`，
不会像 `PyUnicode_AsUTF8` 那样静默截断。

### 2.4 `str` 返回值所有权

RGC 无 GC，`str` 是裸 `malloc` 缓冲区，因此函数返回的指针可能是三种东西之一：
静态字符串字面量（rodata）、调用方自己的参数缓冲区、或新分配的缓冲区。
前两种一旦被 `free` 就会破坏堆或 CPython 的字符串缓存，所以由编译器分类，
胶水只释放**可证明是新分配**的那一种：

| 分类 | 返回表达式 | 胶水行为 |
|------|-----------|---------|
| `owned` | 拼接（`a + b`） | 构造 Python 对象后 `free` |
| `static` | 字符串字面量 | 不释放（rodata） |
| `borrowed` | 参数，或参数构成的链 | 不释放（调用方的缓冲区） |
| `unknown` | 其余一切，如调用返回值 | 不释放，`pyrgc build` 打印告警 |

`owned` 只由 `str` 类型表达式上的 `+` 推出——它必然降级为 `irg_string_concat`
（一次新 `malloc`），而 RGC 没有运算符重载，所以这个推断是可靠的。
其余一律 `unknown` 并保留缓冲区：分析宁可漏（继续泄漏），也绝不误判成
`owned`（堆破坏）。分支与 `match` 的各个出口分别求分类再合并，
只要有一个出口不是 `owned`，整体就是 `unknown`。

拼接链内部的中间缓冲区由编译器自己释放（见 §1.4），不计入这里的分类；
分类只描述**最外层**那个逃逸出来的缓冲区。

### 2.5 当前限制（v0.3）

- 只支持入口文件的标量函数；方法、类、容器（List/Map）导出待后续版本。
- `str` 参数指针仅在调用期间有效（不要把传入的 `str` 长期持有）。
- `str` 返回值分类为 `unknown` 时不回收（每次调用可能泄漏一个缓冲区）；
  改成返回拼接结果即为 `owned`，不再泄漏。
- 无关键字参数、默认值参数；无 `PyErr` 异常传播（RGC 错误建议返回
  `Result` 并在 RGC 层处理）。
- 导出名固定为 RGC 函数名，暂不支持改名导出（PyO3 对应 `#[pyo3(name = ...)]`）。
- 只包装带 `export` 标记的函数；没标记的同名顶层函数不会出现在模块里。

### 2.6 pyrgc 包结构

| 文件 | 说明 |
|------|------|
| `pyrgc/pyproject.toml` | PEP 621 元数据 + `pyrgc` console script |
| `pyrgc/pyrgc/shim.py` | `--emit-exports` 元数据解析（只取 `"export": true` 函数）、vectorcall C 胶水生成（含 docstring 与所有权分类） |
| `pyrgc/pyrgc/builder.py` | 构建编排、`[tool.pyrgc]` 发现与解析 |
| `pyrgc/pyrgc/scaffold.py` | `pyrgc new` 项目模板 |
| `pyrgc/pyrgc/cli.py` | `new` / `build` / `develop` / `--version` |
| `pyrgc/tests/` | pytest：胶水生成单测 + rgc 端到端（无 rgc 自动跳过） |

构建产物中 `pyrgc_shim_<module>.c` 与 `pyrgc_<module>.exports.json`
与 `.so` 一同保留，便于排查胶水与签名问题。

### 2.7 回归测试

- 编译器 FFI：`examples/ffi.rg`（纳入 `rack test` 回归）。
- `--emit-exports`：`tests/exports/suite.rg`（签名 + 11 条所有权规则逐条钉死）。
- 字符串拼接生命周期：`tests/unit/str_concat.rg`（嵌套/右结合/长链/循环累加/
  作为实参/跨函数返回，共 8 例）。
- pyrgc 端到端：`tests/pyrgc/suite.rg`（由 `rack test` 运行；构建 + CPython 实际 import 断言），
  另有 `pyrgc/tests/`（`PYTHONPATH=pyrgc python3 -m pytest pyrgc/tests/`），
  其中包含四种所有权分类的行为断言与 20 万次调用的 RSS 增长断言。

## 3. 实现位置

| 组件 | 路径 |
|------|------|
| extern def 语法/检查/IR | `src/src/{parser,sema,ir}.rg`（`is_extern` / `fn_is_extern`） |
| `export def` 语法与元数据 | `src/src/{parser,ast,exports}.rg`（`is_export`） |
| `--emit-object` / `--shared` / `--emit-exports` | `src/src/main.rg` |
| 导出元数据与 str 所有权分析 | `src/src/exports.rg` |
| 拼接临时缓冲区释放 | `src/src/ir.rg`（`irg_codegen_binary` / `irg_is_temp_concat`） |
| pyrgc Python 包（构建器/CLI/脚手架） | `pyrgc/`（`pip install -e pyrgc/`） |
| 示例 | `examples/ffi.rg`、`examples/pyrgc_demo.rg` |
