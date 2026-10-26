<p align="center">
  <img src="assets/lockup.png" alt="RGC" width="560">
</p>

# RGC

RGC 是一门 Python 风格、编译型、静态类型、带所有权/借用检查的语言，后端使用
LLVM。编译器由 RGC 自身编写（自举），内置语言服务器（LSP），并拥有不断成长的
工具链生态。

<p align="center">
  <a href="https://github.com/rgc-lang/rgc/releases"><img src="https://img.shields.io/github/v/release/rgc-lang/rgc?style=for-the-badge&color=00A060&label=Release" alt="GitHub Release"></a>
  <a href="https://github.com/rgc-lang/rgc"><img src="https://img.shields.io/github/repo-size/rgc-lang/rgc?style=for-the-badge&color=444444&label=Size" alt="GitHub repository size"></a>
  <a href="https://rgc-dev.tensorplay.cn"><img src="https://img.shields.io/badge/Website-rgc--dev.tensorplay.cn-00A060?style=for-the-badge&labelColor=333333&color=00A060" alt="Website"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-F0D010?style=for-the-badge&labelColor=333333&color=00A060" alt="License: Apache-2.0"></a>
</p>

<p align="center">
  <a href="https://github.com/rgc-lang/rgc/actions/workflows/release.yml"><img src="https://github.com/rgc-lang/rgc/actions/workflows/release.yml/badge.svg" alt="Compiler - Release"></a>
  <a href="https://marketplace.visualstudio.com/items?itemName=rgc-dev.rgc-lang"><img src="https://img.shields.io/visual-studio-marketplace/v/rgc-dev.rgc-lang?label=VS%20Code%20Marketplace%20Version" alt="VS Code Marketplace Version"></a>
  <a href="https://marketplace.visualstudio.com/items?itemName=rgc-dev.rgc-lang"><img src="https://img.shields.io/visual-studio-marketplace/i/rgc-dev.rgc-lang?label=VS%20Code%20Marketplace%20Installs" alt="VS Code Marketplace Installs"></a>
</p>

<p align="center">
  [**English**](README.md) · **中文**
</p>

---

## ✨ 认识 RGC

**RGC** 是一门编译型、静态类型语言，采用 Python 风格语法，带所有权/借用检查，
后端基于 LLVM。编译器本身由 RGC 编写——即**自举**——并内置语言服务器（LSP）。

RGC 的目标是：让 Python 开发者感到亲切，同时提供 LLVM 级别的性能与 Rust 风格
所有权检查带来的内存安全。

### 为什么选择 RGC？

- 🐍 **Python 友好**——`def`、`if/elif/else`、`for`、`while`、`match`、`#` 注释，语法熟悉，上手即用。
- ⚡ **原生性能**——LLVM 后端，支持 `-O0` / `-O2` 优化与 DWARF 调试信息。
- 🔒 **编译期内存安全**——所有权与借用检查（`@` / `@var`）在运行前就捕获 use-after-move 与悬垂引用。
- 🧑‍💻 **完整工具链**——包管理器（[`rack`](https://github.com/rgc-lang/rack)）、语言服务器、VS Code 扩展、Python 绑定（[`pyrgc`](https://github.com/rgc-lang/pyrgc)）。

### 核心特性

- ✏️ Python 风格语法：`def`、`if/elif/else`、`for`、`while`、`match`、`#` 注释。
- 🧩 静态类型：`int`、`float`、`bool`、`str`、泛型、接口与边界约束。
- 🔒 所有权与借用检查（`@` / `@var`）。
- ⚡ LLVM 后端，支持 `-O0` / `-O2` 优化与 DWARF 调试信息。
- 📦 模块系统（`import` + `public`）与 FFI（`extern def`）。
- 📚 标准库：字符串、列表、JSON、正则、网络（TCP/UDP/HTTP/HTTPS）、async/await、TLS。
- 🧩 Python 绑定：[pyrgc](https://github.com/rgc-lang/pyrgc)。
- 📦 包管理：[rack](https://github.com/rgc-lang/rack)。

## 🚀 快速开始

依赖：已发布的 `rgc` 编译器（用于构建当前源码）、LLVM 23 开发库、`g++`/`gcc`、
CMake，以及位于 `../rack` 的 [`rack`](https://github.com/rgc-lang/rack) 检出。

Windows ARM64 请使用 MSYS2 的 `CLANGARM64` 工具链
（`mingw-w64-clang-aarch64-llvm` 与 `mingw-w64-clang-aarch64-gcc-compat`），
并把 `C:\msys64\clangarm64\bin` 加入 `PATH`；发布工作流会自动完成这一步。

```bash
cd src
./build.sh        # rgc1 -> rgc2 -> rgc3（由 rack 管理）
RGC=build/rgc3 ../rack/target/bin/rack test ../tests ../examples   # 原生回归测试（`rack test`）

# 编译并运行
./build/rgc3 ../examples/hello.rg -o /tmp/hello
/tmp/hello
```

> `build.sh` 使用 `PATH` 中的 `rgc`（或 `RGC_BOOTSTRAP=/path/to/rgc`）构建当前
> 源码；请先安装[最新发布版](https://github.com/rgc-lang/rgc/releases)。

### Hello, World!

```python
def main() {
    print("Hello, RGC!")
}
```

## 🧩 编辑器支持

从 [Visual Studio Code Marketplace](https://marketplace.visualstudio.com/items?itemName=rgc-dev.rgc-lang)
安装官方 **RGC for VS Code** 扩展——由 `rgc-analyzer` 语言服务器驱动，提供语法高亮、
代码片段与 build/run/test 命令。

## 🛠️ 编译器（`rgc`）

编译器通过 rack 管理的三个阶段（`rgc1 -> rgc2 -> rgc3`）构建，每个阶段都用
RGC 自身编写；构建过程会验证最后两个阶段产出的 self-IR 完全一致。

### 文档

- [语言设计规范](docs/compiler/DESIGN.md)
- [标准库规范](docs/compiler/STDLIB.md)
- [FFI 与 pyrgc](docs/compiler/FFI.md)

### 生态

- [rack](https://github.com/rgc-lang/rack) —— 包管理器与构建系统
- [pyrgc](https://github.com/rgc-lang/pyrgc) —— CPython 扩展绑定
- [analyzer](https://github.com/rgc-lang/analyzer) —— `rgc-analyzer` 语言服务器与 RGC VS Code 扩展

## 🤝 参与贡献

欢迎提交 issue、PR 与参与讨论！请在 GitHub 上打开
[issue](https://github.com/rgc-lang/rgc/issues) 或直接提交 pull request。

## 📄 许可证

[Apache-2.0](LICENSE)。