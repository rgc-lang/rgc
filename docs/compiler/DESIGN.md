# RGC 语言设计规范（工作名，正式名待定）

> 状态：草案 v0.2
> 定位：**Python 风格、编译型、静态类型**的系统编程语言
> 口号：Python 开发者的编译型语言——类 Py 语法，LLVM 性能，内存安全

---

## 1. 设计目标

RGC 让 Python 开发者用熟悉的语法编写**编译型、静态类型、内存安全**的程序，同时保持现代语言的表达力。

| 原则 | 说明 |
|------|------|
| **类 Py** | 关键词和语法习惯对齐 Python：`def`/`if`/`elif`/`else`/`for`/`while`/`return`/`and`/`or`/`not`/`True`/`False`/`None`、`#` 注释、`x: int = 42` 类型注解 |
| **不用缩进** | 块结构用大括号 `{}`，无缩进敏感，重构友好，编译器简单 |
| **编译型** | LLVM 后端，生成原生机器码，性能接近 C/Rust |
| **静态类型** | 编译期类型检查 + 类型推断，`int`/`float`/`bool`/`str` |
| **内存安全** | 所有权 + 借用检查（无 GC），**变量默认可变**（Python 习惯） |
| **现代** | 表达式值、代数数据类型（ADT）、模式匹配、泛型（后期） |
| **自举（终极目标）** | 最终 RGC 编译器用 RGC 自身编写，C++ 实现只是引导编译器 |

## 2. 与 Python / Rust 的差异定位

| 维度 | Python | Rust | RGC |
|------|--------|------|-----|
| 执行方式 | 解释 | 编译 | **编译（LLVM）** |
| 类型系统 | 动态 | 静态+推断 | **静态+推断** |
| 块结构 | 缩进 | 大括号 | **大括号** |
| 变量默认 | 可变 | 不可变（`mut`） | **可变（无 `mut`）** |
| 内存管理 | GC | 所有权+借用 | **所有权+借用** |
| 函数 | `def` | `fn` | **`def`** |
| 逻辑运算符 | `and or not` | `&& \|\| !` | **`and or not`** |
| 循环 | `for ... in` / `while` | `for`/`loop`/`while` | **`for ... in` / `while`** |
| 空值 | `None` | `()` / `Option` | **`None`** |
| 借用符号 | 无 | `&` / `&mut` | **`@` / `@var`** |

RGC 的关键词（`def`/`class`/`enum`/`match`/`case`/`if`/`elif`/`else`/`for`/`while`/`return`/`and`/`or`/`not`/`True`/`False`/`None`）**全部来自 Python 生态**，与 Rust 的词汇（`fn`/`let`/`mut`/`struct`/`impl`/`trait`/`mod`/`pub`/`&`）**零重叠**。

## 3. 语法设计

### 3.1 基本结构

```python
# 入口函数（Python 风格）
def main() {
    x = 42                    # 变量绑定，推断为 int
    y: float = 3.14           # 显式类型注解
    print("sum =", x + y)     # 输出: sum = 45.14
}
```

### 3.2 变量绑定

- 赋值即声明，**默认可变**（Python 风格）。
- 类型可显式注解（`x: int = 42`），也可推断（`x = 42` → `int`）。

```python
a = 42                # 推断为 int
b: float = 3.14       # 显式 float
c = a + 1             # 引用已声明的变量
c = c * 2            # 可变绑定可重新赋值
```

### 3.3 基础类型

| 类型 | 说明 | 对应 LLVM |
|------|------|-----------|
| `int` | 有符号 64 位整数 | `i64` |
| `float` | 双精度浮点 | `double` |
| `bool` | 布尔值 | `i1` |
| `str` | 字符串（Phase 8 标准库完善） | 指针 |
| `None` | 无值（对应 Python `None`） | `void` |

### 3.4 函数

```python
def add(a: int, b: int) -> int {
    return a + b        # 显式 return（Python 风格）
}

def main() {
    total = add(3, 4)
    print(total)        # 7
}
```

### 3.5 控制流

```python
def classify(score: int) -> str {
    if score >= 90 {
        return "excellent"
    } elif score >= 60 {
        return "pass"
    } else {
        return "fail"
    }
}

def main() {
    n = 3
    while n > 0 {
        print(n)
        n = n - 1       # 可变变量，Python 风格
    }
    for i in range(5) {  # Phase 4 实现
        print(i)
    }
}
```

### 3.6 逻辑运算符（Python 风格）

```python
if x > 0 and x < 100 { ... }
if not flag { ... }
if a == b or c == d { ... }
```

### 3.7 类与枚举（ADT，Phase 4）

```python
class Point {
    x: int
    y: int
}

enum Shape {
    Circle(float)
    Rect { w: float, h: float }
}
```

### 3.8 模式匹配（Phase 4）

```python
def area(s: Shape) -> float {
    match s {
        case Circle(r)     => 3.14159 * r * r
        case Rect { w, h } => w * h
        case _              => 0.0
    }
}
```

### 3.9 方法（Phase 4）

```python
class Point {
    x: int
    y: int

    def sum(self) -> int {
        return self.x + self.y
    }
}
```

### 3.10 所有权与借用（Phase 5/6）

- 标量类型（`int`/`float`/`bool`/`str`）按值拷贝。
- 容器/自定义类型按 **move** 语义转移所有权。
- 借用符号：`@x` 不可变借用，`@var x` 可变借用（**不用 Rust 的 `&`/`&mut`**）。

```python
def main() {
    a = Box(10)        # a 拥有 Box
    b = a              # move：a 的所有权转移给 b
    # print(a)         # 编译错误：use of moved value: `a`
}
```

**Phase 5 已落地（AST 级保守所有权分析）**：
- 赋值 `b = a`、传参 `foo(a)`、返回 `return a` 触发 move；重新赋值恢复可用。
- `match`/方法调用 `p.sum()`/成员读取 `p.x` 视为只读借用，不 move。
- 分支（`if`/`match`/`for`）之间做**状态隔离 + 保守合并**（任一路径 moved → 之后视为 moved）。
- 分析是纯编译期、单遍 + 哈希索引合并（近线性时间），**零运行时开销**。

**Phase 6 已落地（AST 级词法借用分析）**：
- 借用类型：`@Point`（共享/只读）、`@var Point`（可变/可写）；`@x`/`@var x` 是借用表达式。
- 调用点借用：`foo(@x)` 的借用只在调用期间活跃；`foo(@var x)` 需要无其他活跃借用。
- 词法借用手柄：`r = @x` 的借用持续到当前作用域结束（作用域弹出自动释放），保守但线性。
- 借用期间：共享借用只读（不能写字段）、可变借用独占（所有者不可读）、被借用变量不能 move。
- 完整 MIR 留待后续（泛型/接口阶段若需要再做）。

### 3.11 泛型与接口

- **泛型函数**：`def identity[T](x: T) -> T`。调用时按实参类型推断类型参数，**单态化**生成具体函数（`identity$int`），实例化缓存保证同参组合只生成一次。
- **泛型类**：`class Box[T] { value: T }`。类型注解 `Box[int]`、构造 `Box[int]()`、字段访问与方法调用均按具体类型实例化（`Box$int` / `Box$int_get`）。
- **泛型枚举**：`enum Maybe[T] { Some(T) Nothing }`。构造 `Maybe[int].Some(42)` 时按类型实参实例化（`Maybe$int`），变体字段类型随之替换；`match` 模式匹配走具体枚举布局。同一泛型枚举有多种实例化时，裸变体构造（`Some(42)`）可能产生歧义，应使用显式 `Maybe[int].Some(42)`。
- **泛型边界约束**：`def describe[T: Show](x: T) -> str` 与 `class Box[T: Show]`。实例化时校验类型参数显式实现了对应接口（`class X : Show`），函数/方法体内对 `T` 的接口方法调用在实例化后静态分派到具体类方法（如 `Point_show`）。
- **接口**：`interface Show { def show(self) -> str }`；类通过 `class Point : Show` 显式声明实现，编译器检查方法签名（忽略 `self`）是否匹配。
- **类型布局**：CodeGen 先预声明全部类/枚举类型名（空占位结构体），再统一填充布局，因此类/枚举字段可以前向引用后续才被惰性实例化的泛型类型（如 `class Holder { b: Box[int] }`）。
- **性能**：单态化是编译期展开，无虚表/装箱/动态分派，运行时零开销。

### 3.12 模块系统（命名空间化）

- **`import foo` / 层级路径 `import net/tcp`**：加载入口目录或标准库目录下的 `foo.rg`；路径可含 `/`（如 `net/tcp.rg`），物理前缀规范化为 `net$tcp`（保证 LLVM 符号合法）。限定调用绑定路径末段（`tcp.ping()`），`as` 可覆盖绑定名（`import net/tcp as nt`）；同一作用域重复绑定同名报冲突。`name.rg` 缺席时回退 `name/mod.rg`（对齐 Rust `mod.rs` 约定）。
- **循环引用合法（对齐 Rust）**：loader 遇到正在加载中的模块直接跳过（不再报错）；符号物理隔离 + Sema 在全量合并 AST 后统一解析，`a -> b -> a` 双向调用与双向 from-import 均可用。
- **`from foo import a, b as c` / glob `from foo import *`**：名单真正生效——在所属模块（或入口文件）作用域建立 `别名 -> foo.原名` 映射；`as` 支持重命名。`*` 只导入公开符号（函数/泛型/类/枚举/接口），解析优先级低于本地定义与 from-import：本地声明 > from-import > glob > 唯一导出者回退；多个 glob 源导出同名符号时裸名调用报歧义。
- **重导出（`public from foo import a as b`，对齐 Rust `pub use`）**：把源模块的公开符号挂到当前模块的导出表；链式重导出（c 重导出 a 重导出的符号）按不动点迭代解析。函数/泛型经 `module_exports`，类型经 `type_reexports` 跟随链；私有类型重导出报错（对齐 Rust E0365），无目标的 public from-import 报 `cannot re-export` 错误。入口文件（crate 根）的重导出仅作普通导入。
- **物理命名空间（module$name）**：模块顶层符号（函数、泛型模板、类、枚举、接口）统一注册为 `module$name` 物理名，入口文件保持裸名。不同模块的同名公开函数、同名类型、同名泛型模板互不冲突（此前同名公开函数会在 codegen 阶段符号冲突）。
- **裸名解析链**：本模块声明 -> from-import 别名 -> 裸名（入口/内建）-> glob 导入候选 -> 唯一导出者回退 -> 歧义报错。两个模块导出同名符号时，裸名调用报歧义错误（`function "f" is ambiguous: exported by modules m1, m2`）；类型同理。
- **调用点符号记录（call_syms）**：Sema 解析裸名/限定/泛型调用时把「调用点 -> 物理符号」记入 `call_syms`（键 = 模块前缀 + 行:列，避免跨模块同位置调用点冲突），IR 直接采用，不再重复推导命名规则。模块内泛型函数实例的命名因此与定义符号一致（此前模块内私有泛型直接链接失败），并新增支持限定调用模块泛型 `m.pick(7)`。
- **`public` 可见性**：模块顶层项默认模块私有，`public` 修饰后导出；跨模块引用私有符号时编译报错。诊断信息还原源码原名（不暴露 `module$` 物理名）。
- **主程序符号不受限**：入口文件的顶层符号对模块始终可见（无 `public` 要求）。
- **语句位置 if**：语句位置的 `if/else` 不再要求分支尾表达式类型一致（值被丢弃），表达式位置仍检查；`lib/net.rg` 等系统库代码依赖此语义。
- **extern 声明按函数名去重**：多个标准库模块重复 `extern def` 同一 C 函数（文本格式可能不同）只发一条 `declare`。

### 3.13 FFI（extern def / export def）

- **`extern def name(...) -> ret`**：声明 C ABI 外部函数（无函数体），符号由链接器解析（libc 默认已链接，其他库用 `--link-args`）。`extern` 是上下文修饰符（非关键词），符号保持裸名、不做模块改名。
- **类型映射**：参数 `int`=i64 / `float`=double / `bool`=_Bool(i8) / `str`=ptr；返回 `int`=C int(i32，调用点 sext 回 64 位) / `bool` 按 C 真值语义（非零即真）/ `None`=void。
- **限制**：不能有函数体、不能泛型、不支持自定义类型与借用。
- **`--emit-object`**：只产出目标文件；**`--shared`**：链接为共享库（输出为 PIC）。
- **`export def name(...)`**：声明该函数可被宿主运行时的绑定生成器包装（与 `extern` 一样是上下文修饰符、非关键词）。与 `public` 正交：`public` 管 RGC 模块间可见性，`export` 管宿主可见性；`public export def` 同时具备两者。标记只进 `--emit-exports` 元数据（`"export": true`），不改变生成代码，标准库不需要任何绑定运行时模块。
- **pyrgc**：官方 Python 绑定框架（CPython C API），只包装带 `export` 标记的入口文件函数，签名取自编译器元数据，详见 [FFI.md](FFI.md)。

## 4. 类型系统

- **静态 + 强类型**：类型编译期确定；`int` 与 `float` 混合运算时自动提升为 `float`。
- **类型推断**：双向类型检查（Bidirectional Type Checking）。
- **类型名**：`int`/`float`/`bool`/`str`/`None`（Python 风格小写，非保留字，仅在类型位置解析）。

## 5. 编译管线

```
源代码 (.rg)
  │
  ▼
Lexer（词法）─────────► Token 流（含 # 注释、// 整除、** 幂）
  │
  ▼
Parser（递归下降）──────► AST（带源码位置）
  │
  ▼
TypeChecker（类型检查）──► HIR（类型标注、作用域）
  │
  ▼
Ownership + Borrow Check（所有权+借用）─► AST 级线性分析（Phase 5 move + Phase 6 @/@var 词法借用）
  │
  ▼
CodeGen（LLVM IR）─────► LLVM IR (.ll / .o)
  │
  ▼
链接 ──────────────────► 可执行文件
```

## 6. 明确不做什么（第一版）

- ❌ 缩进敏感语法（用大括号）
- ❌ Rust 风格词汇（`fn`/`let`/`mut`/`struct`/`trait`/`&`）
- ❌ 完整泛型系统（Phase 7）
- ❌ 协程 / 事件循环（`async` 已用 pthread 线程池实现，见 `STDLIB.md` §10）
- ❌ 不安全代码
- ❌ 包管理器、LSP（Phase 9）

---

> 本文档随实现迭代更新。