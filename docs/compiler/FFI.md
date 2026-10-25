# FFI 与 pyrig —— C 互操作与 Python 绑定

> 状态：v0.2（Phase 10 首批落地）
> 组成：编译器 `extern def`（C ABI 外部函数声明）+ `pyrig` 官方 Python 绑定框架（CPython C API）

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

RGC 输出的目标文件是 PIC（位置无关），可直接参与共享库链接。

---

## 2. pyrig：Python 绑定框架

`pyrig` 是 RGC 的官方 Python 绑定框架，定位对齐 pybind11 / PyO3：
把 RGC 函数导出为 **CPython 扩展模块**，Python 侧直接 `import`。
实现直接走 **CPython C API**：pyrig 构建器为每个导出函数生成
`PyArg_ParseTuple` 参数解析 + 类型转换 + `PyMethodDef` 方法表 +
`PyInit_<module>` 模块入口的 C 胶水，再用 `rgc --emit-object` 编译 RGC 代码，
链接为 `.so`（不依赖 libpython，符号由解释器在 import 时解析——与 CPython
官方扩展构建方式一致）。

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
  由 pyrig 构建器静态扫描；运行时为空操作。
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

| RGC | Python | 参数解析 | 返回值构造 |
|-----|--------|----------|------------|
| `int` | `int` | `"L"` (long long) | `PyLong_FromLongLong` |
| `float` | `float` | `"d"` | `PyFloat_FromDouble` |
| `bool` | `bool` | `"p"` | `PyBool_FromLong` |
| `str` | `str` | `"s"` (UTF-8) | `PyUnicode_FromString` |
| `None` | `None` | — | `Py_RETURN_NONE` |

参数个数/类型不符时由 CPython 抛出标准 `TypeError`。

### 2.4 当前限制（v0.2）

- 只支持入口文件的标量函数；方法、类、容器（List/Map）导出待后续版本。
- `str` 参数指针仅在调用期间有效（不要把传入的 `str` 长期持有）；
  `str` 返回值由 RGC 侧分配且无 GC，当前会延迟释放（无回收）。
- 无关键字参数、默认值参数；无 `PyErr` 异常传播（RGC 错误建议返回
  `Result` 并在 RGC 层处理）。
- `pyrig.export("py 名", "rgc 函数名")` 改名导出时，两函数的签名必须
  ABI 兼容（胶水按被导出函数的 C 签名声明）。

### 2.5 pyrig 包结构

| 文件 | 说明 |
|------|------|
| `pyrig/pyproject.toml` | PEP 621 元数据 + `pyrig` console script |
| `pyrig/pyrig/shim.py` | `pyrig.export` 扫描、签名解析、C 胶水生成（含 docstring） |
| `pyrig/pyrig/builder.py` | 构建编排、`[tool.pyrig]` 发现与解析 |
| `pyrig/pyrig/scaffold.py` | `pyrig new` 项目模板 |
| `pyrig/pyrig/cli.py` | `new` / `build` / `develop` / `--version` |
| `pyrig/tests/` | pytest：胶水生成单测 + rgc 端到端（无 rgc 自动跳过） |

### 2.6 回归测试

- 编译器 FFI：`examples/ffi.rg`（纳入 `rack test` 回归）。
- pyrig 端到端：`tests/pyrig/suite.rg`（由 `rack test` 运行；构建 + CPython 实际 import 断言），
  另有 `pyrig/tests/`（`PYTHONPATH=pyrig python3 -m pytest pyrig/tests/`）。

## 3. 实现位置

| 组件 | 路径 |
|------|------|
| extern def 语法/检查/IR | `src/src/{parser,sema,ir}.rg`（`is_extern` / `fn_is_extern`） |
| `--emit-object` / `--shared` | `src/src/main.rg` |
| pyrig 运行时模块 | `lib/pyrig.rg` |
| pyrig Python 包（构建器/CLI/脚手架） | `pyrig/`（`pip install -e pyrig/`） |
| 示例 | `examples/ffi.rg`、`examples/pyrig_demo.rg` |
