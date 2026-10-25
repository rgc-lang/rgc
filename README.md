<p align="center">
  <img src="assets/lockup.png" alt="RGC" width="560">
</p>

# RGC

RGC is a Python-style, compiled, statically typed programming language with
ownership/borrow checking and an LLVM backend — self-hosted, with a built-in
language server and a growing ecosystem.

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
  <b>English</b> · [**中文**](README.zh-CN.md)
</p>

---

## ✨ Introducing RGC

**RGC** is a compiled, statically typed programming language with Python-style
syntax, ownership/borrow checking, and an LLVM backend. The compiler is written
in RGC itself — it is self-hosted — and ships with a built-in Language Server
(LSP).

RGC aims to be friendly to Python developers while giving you the performance of
LLVM and the memory safety of Rust-style ownership checking.

### Why Choose RGC?

- 🐍 **Python-friendly** — familiar `def`, `if/elif/else`, `for`, `while`, `match`, and `#` comments, so Python developers feel at home from day one.
- ⚡ **Native performance** — LLVM backend with `-O0` / `-O2` optimization and DWARF debug info.
- 🔒 **Memory safety at compile time** — ownership and borrow checking (`@` / `@var`) catch use-after-move and dangling references before you run.
- 🧑‍💻 **Full toolchain** — package manager ([`rack`](https://github.com/rgc-lang/rack)), language server, VS Code extension, and Python bindings ([`pyrig`](https://github.com/rgc-lang/pyrig)).

### Key Features

- ✏️ Python-like syntax: `def`, `if/elif/else`, `for`, `while`, `match`, `#` comments.
- 🧩 Static typing with `int`, `float`, `bool`, `str`, generics, interfaces, and bounds.
- 🔒 Ownership and borrow checking (`@` / `@var`).
- ⚡ LLVM backend with `-O0` / `-O2` optimization and DWARF debug info.
- 📦 Module system (`import` + `public`) and FFI (`extern def`).
- 📚 Standard library: strings, lists, JSON, regex, networking (TCP/UDP/HTTP/HTTPS), async/await, and TLS.
- 🧩 Python bindings via [pyrig](https://github.com/rgc-lang/pyrig).
- 📦 Package management via [rack](https://github.com/rgc-lang/rack).

## 🚀 Quick Start

Prerequisites: a released `rgc` compiler (used to build the current sources),
LLVM 23 development libraries, `g++`/`gcc`, CMake, and a
[`rack`](https://github.com/rgc-lang/rack) checkout at `../rack`.

On Windows ARM64, use the MSYS2 `CLANGARM64` toolchain
(`mingw-w64-clang-aarch64-llvm` and `mingw-w64-clang-aarch64-gcc-compat`) and
put `C:\msys64\clangarm64\bin` on `PATH`. The release workflow sets this up
automatically.

```bash
cd src
./build.sh        # rgc1 -> rgc2 -> rgc3 (managed by rack)
RGC=build/rgc3 ../rack/target/bin/rack test ../tests ../examples   # native regression tests (`rack test`)

# compile and run
./build/rgc3 ../examples/hello.rg -o /tmp/hello
/tmp/hello
```

> `build.sh` uses the `rgc` found on `PATH` — or `RGC_BOOTSTRAP=/path/to/rgc` —
> to build the current sources. Install the
> [latest release](https://github.com/rgc-lang/rgc/releases) first.

### Hello, World!

```python
def main() {
    print("Hello, RGC!")
}
```

## 🧩 Editor Support

Install the official **RGC for VS Code** extension from the
[Visual Studio Code Marketplace](https://marketplace.visualstudio.com/items?itemName=rgc-dev.rgc-lang) —
powered by the `rgc-analyzer` language server, with syntax highlighting, snippets,
and build/run/test commands.

## 🛠️ The Compiler (`rgc`)

The compiler is built in three rack-managed stages (`rgc1 -> rgc2 -> rgc3`),
each written in RGC itself; the build verifies that the last two stages produce
identical self-IR.

### Documentation

- [Language design](docs/compiler/DESIGN.md)
- [Standard library](docs/compiler/STDLIB.md)
- [FFI and pyrig](docs/compiler/FFI.md)

### Ecosystem

- [rack](https://github.com/rgc-lang/rack) — package manager and build system
- [pyrig](https://github.com/rgc-lang/pyrig) — CPython extension bindings
- [analyzer](https://github.com/rgc-lang/analyzer) — `rgc-analyzer` language server and the RGC VS Code extension

## 🤝 Contributing

Issues, pull requests, and discussions are welcome! Open an
[issue](https://github.com/rgc-lang/rgc/issues) or submit a pull request.

## 📄 License

[Apache-2.0](LICENSE).