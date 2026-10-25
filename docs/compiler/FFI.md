# FFI 与 pyrig —— C 互操作与 Python 绑定

> 状态：v0.3（Phase 10 首批落地 + vectorcall 胶水 + str 所有权）
> 组成：编译器 `extern def`（C ABI 外部函数声明）+ `--emit-exports`（签名/所有权元数据）+ `pyrig` 官方 Python 绑定框架（CPython C API）

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
| `--emit-object` | 只生成目标文件（`.o`），不链接（pyrig 构建流程使用） |
| `--shared` | 链接为共享库（`g++ -shared -fPIC`），供 pyrig / 插件场景使用 |
| `--emit-exports <json>` | 额外写出入口文件全部顶层函数的签名与 `str` 返回值所有权分类（绑定生成器使用） |

RGC 输出的目标文件是 PIC（位置无关），可直接参与共享库链接。

`--emit-exports` 的 JSON 在语义检查通过后、IR 生成之前写出，因此它与
`--emit-llvm` 可以同时使用，也不受后端崩溃影响：

```json
{"format": 1, "source": "examples/pyrig_demo.rg",
 "functions": [{"name": "greet", "public": true,
                "params": [{"name": "name", "type": "str"}],
                "ret": "str", "str_ret": "owned"}]}
```

签名由编译器发布而不是让绑定生成器用正则去刮源码：类型解析、默认值、
`@`/`@var` 借用前缀都只有编译器知道，两边各写一份解析器必然失同步。

### 1.3 字符串拼接的临时缓冲区

`str` 是裸 `malloc` 缓冲区且 RGC 无 GC，链式 `a + b + c` 会为每个 `+`
分配一个缓冲区，但只有最外层的那个会逃逸出表达式。代码生成在字节拷贝完成后
立即释放嵌套的中间缓冲区（它们是刚 malloc 出来的一次性临时值，没有任何
其他引用），因此链长不再影响常驻内存：1/2/4 段链的峰值 RSS 修复前为
7.3/13.6/26.1 MB，修复后同为 7.4 MB 基线。最外层缓冲区仍然由调用方
（pyrig 胶水或 RGC 变量作用域）负责。

---

## 2. pyrig：Python 绑定框架

`pyrig` 是 RGC 的官方 Python 绑定框架，定位对齐 pybind11 / PyO3：
把 RGC 函数导出为 **CPython 扩展模块**，Python 侧直接 `import`。
实现直接走 **CPython C API**：pyrig 构建器先用
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
# examples/pyrig_demo.rg
import pyrig

public def add(a: int, b: int) -> int {
    return a + b
}

public def greet(name: str) -> str {
    return "hello, " + name + "!"
}

public def is_even(n: int) -> bool {
    return n % 2 == 0
}

# pybind11: PYBIND11_MODULE(demo, m) { m.def("add", &add); ... }
pyrig.export("add")
pyrig.export("greet")
pyrig.export("is_even")
# 指定不同名：pyrig.export("py_add", "add")
```

- 导出函数必须写在**入口文件**且带**显式类型注解**（胶水需要 C 签名）。
- `pyrig.export("名")` 是编译期标记（顶层语句不参与代码生成），
  由 pyrig 构建器静态扫描，**决定导出哪些函数**；签名与类型则来自
  `--emit-exports` 元数据，两边不重复解析源码。运行时为空操作。
- 支持的导出类型：`int` / `float` / `bool` / `str` / `None`。

### 2.2 安装、构建与使用

pyrig 以标准 Python 包分发（参考 PyO3/maturin 的模式，`pyrig/pyproject.toml`）：

```bash
pip install -e pyrig/                 # 或 PYTHONPATH=pyrig python3 -m pyrig
```

maturin 风格工作流：

```bash
pyrig new string_sum                  # 脚手架：string_sum.rg + pyproject.toml
cd string_sum && pyrig build          # -> dist/string_sum.<ext-suffix>.so
pyrig develop                         # 构建并安装到激活的 virtualenv
```

直接构建（仓库根目录）：

```bash
pyrig build examples/pyrig_demo.rg -n pyrig_demo -o build/pyrig
#   built: build/pyrig/pyrig_demo.cpython-313-x86_64-linux-gnu.so (5 exports: add, greet, is_even, dist, say_hi)

python3 -c "
import sys; sys.path.insert(0, 'build/pyrig')
import pyrig_demo
print(pyrig_demo.add(3, 4))        # 7
print(pyrig_demo.greet('rgc'))     # hello, rgc!
print(pyrig_demo.is_even(10))      # True
print(pyrig_demo.add.__doc__)      # 函数上方 # 注释成为 __doc__（对齐 PyO3 doc comment）
"
```

`build` 选项：`-n` 模块名（默认文件名）、`-o` 输出目录、`--rgc` 编译器路径
（默认 `RGC` env / `PATH` / 仓库 `build/rgc`）、`--cc` C 编译器（默认 `cc`）、
`--debug` 关闭优化（`rgc -O0`）。项目内 `pyrig build` 自动向上发现
`pyproject.toml` 的 `[tool.pyrig]` 段（`name`/`source`/`out-dir`/`rgc`/`cc`/`release`/`link-args`）。

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
| `unknown` | 其余一切，如调用返回值 | 不释放，`pyrig build` 打印告警 |

`owned` 只由 `str` 类型表达式上的 `+` 推出——它必然降级为 `irg_string_concat`
（一次新 `malloc`），而 RGC 没有运算符重载，所以这个推断是可靠的。
其余一律 `unknown` 并保留缓冲区：分析宁可漏（继续泄漏），也绝不误判成
`owned`（堆破坏）。分支与 `match` 的各个出口分别求分类再合并，
只要有一个出口不是 `owned`，整体就是 `unknown`。

拼接链内部的中间缓冲区由编译器自己释放（见 §1.3），不计入这里的分类；
分类只描述**最外层**那个逃逸出来的缓冲区。

### 2.5 当前限制（v0.3）

- 只支持入口文件的标量函数；方法、类、容器（List/Map）导出待后续版本。
- `str` 参数指针仅在调用期间有效（不要把传入的 `str` 长期持有）。
- `str` 返回值分类为 `unknown` 时不回收（每次调用可能泄漏一个缓冲区）；
  改成返回拼接结果即为 `owned`，不再泄漏。
- 无关键字参数、默认值参数；无 `PyErr` 异常传播（RGC 错误建议返回
  `Result` 并在 RGC 层处理）。
- `pyrig.export("py 名", "rgc 函数名")` 改名导出时，两函数的签名必须
  ABI 兼容（胶水按被导出函数的 C 签名声明）。

### 2.6 pyrig 包结构

| 文件 | 说明 |
|------|------|
| `pyrig/pyproject.toml` | PEP 621 元数据 + `pyrig` console script |
| `pyrig/pyrig/shim.py` | `pyrig.export` 扫描、`--emit-exports` 元数据解析、vectorcall C 胶水生成（含 docstring 与所有权分类） |
| `pyrig/pyrig/builder.py` | 构建编排、`[tool.pyrig]` 发现与解析 |
| `pyrig/pyrig/scaffold.py` | `pyrig new` 项目模板 |
| `pyrig/pyrig/cli.py` | `new` / `build` / `develop` / `--version` |
| `pyrig/tests/` | pytest：胶水生成单测 + rgc 端到端（无 rgc 自动跳过） |

构建产物中 `pyrig_shim_<module>.c` 与 `pyrig_<module>.exports.json`
与 `.so` 一同保留，便于排查胶水与签名问题。

### 2.7 回归测试

- 编译器 FFI：`examples/ffi.rg`（纳入 `rack test` 回归）。
- `--emit-exports`：`tests/exports/suite.rg`（签名 + 11 条所有权规则逐条钉死）。
- 字符串拼接生命周期：`tests/unit/str_concat.rg`（嵌套/右结合/长链/循环累加/
  作为实参/跨函数返回，共 8 例）。
- pyrig 端到端：`tests/pyrig/suite.rg`（由 `rack test` 运行；构建 + CPython 实际 import 断言），
  另有 `pyrig/tests/`（`PYTHONPATH=pyrig python3 -m pytest pyrig/tests/`），
  其中包含四种所有权分类的行为断言与 20 万次调用的 RSS 增长断言。

## 3. 实现位置

| 组件 | 路径 |
|------|------|
| extern def 语法/检查/IR | `src/src/{parser,sema,ir}.rg`（`is_extern` / `fn_is_extern`） |
| `--emit-object` / `--shared` / `--emit-exports` | `src/src/main.rg` |
| 导出元数据与 str 所有权分析 | `src/src/exports.rg` |
| 拼接临时缓冲区释放 | `src/src/ir.rg`（`irg_codegen_binary` / `irg_is_temp_concat`） |
| pyrig 运行时模块 | `lib/pyrig.rg` |
| pyrig Python 包（构建器/CLI/脚手架） | `pyrig/`（`pip install -e pyrig/`） |
| 示例 | `examples/ffi.rg`、`examples/pyrig_demo.rg` |
