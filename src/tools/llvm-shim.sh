#!/usr/bin/env bash
# Compile the stage1 LLVM backend shim and generate the rgc link-argument file.
#
# Invoked by rack build's [build].prebuild (cwd = project root).
# Outputs:
#   target/build/llvm_shim.o   —— the C ABI implementation of emit_object
#   target/build/link-args     —— passed by rack to rgc as --link-args

set -euo pipefail
cd "$(dirname "$0")/.."

LLVM_BIN="${LLVM_BIN:-/home/bluemoon/llvm/LLVM-23.1.4-Linux-X64/bin}"
LLVM_PREFIX="$(cd "$LLVM_BIN/.." && pwd)"
LLVM_CONFIG="$LLVM_BIN/llvm-config"

if [ ! -x "$LLVM_CONFIG" ]; then
    echo "error: llvm-config not found at $LLVM_CONFIG" >&2
    exit 1
fi

host_arch="$(uname -m)"
if [ "${PROCESSOR_ARCHITECTURE:-}" = "ARM64" ]; then
    host_arch="aarch64"
fi
case "$host_arch" in
    aarch64 | arm64)
        target_components="aarch64codegen aarch64asmparser"
        # Windows ARM64 uses the CLANGARM64 libc++; other hosts use libstdc++.
        if [ "${OS:-}" = "Windows_NT" ]; then
            cxx_runtime="-lc++"
        else
            cxx_runtime="-lstdc++"
        fi
        ;;
    *)
        target_components="x86codegen x86asmparser"
        cxx_runtime="-lstdc++"
        ;;
esac
# macOS clang++ links libc++ by default and has no libstdc++.
if [ "$(uname -s)" = "Darwin" ]; then
    cxx_runtime=""
fi

thread_lib="-lpthread"
if [ "${OS:-}" = "Windows_NT" ] && [ "$host_arch" != "x86_64" ]; then
    thread_lib=""
fi

mkdir -p target/build
SHIM_OBJ=target/build/llvm_shim.o
if [ ! -f "$SHIM_OBJ" ] || [ llvm_shim.cpp -nt "$SHIM_OBJ" ]; then
    "${CXX:-g++}" -c -O2 -fPIC -std=c++17 $("$LLVM_CONFIG" --cxxflags) llvm_shim.cpp -o "$SHIM_OBJ"
fi

LLVM_LIBS="$("$LLVM_CONFIG" --libs core irreader passes target $target_components)"
LLVM_SYSTEM="$("$LLVM_CONFIG" --system-libs)"
printf '%s\n' \
    "$PWD/$SHIM_OBJ -L$LLVM_PREFIX/lib $LLVM_LIBS $LLVM_SYSTEM $thread_lib $cxx_runtime" \
    > target/build/link-args
