#!/usr/bin/env bash
# RGC vs C++ benchmark runner.
# Usage:
#   ./benchmarks/run.sh
#   RGC=build/rgc CXX=g++ ./benchmarks/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RGC="${RGC:-$ROOT/build/rgc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$RGC" ]; then
    echo "error: RGC compiler not found at $RGC" >&2
    echo "build it first: cd src && ./build.sh" >&2
    exit 1
fi

# Locate clang: prefer PATH, then LLVM_BIN.
CLANG="$(command -v clang || true)"
if [ -z "$CLANG" ] && [ -n "${LLVM_BIN:-}" ] && [ -x "$LLVM_BIN/clang" ]; then
    CLANG="$LLVM_BIN/clang"
fi

run_best() { # run_best <binary> [args...] -> best ms
    local bin="$1"; shift
    local best=999999
    for _ in 1 2 3; do
        local start end ms
        start=$(date +%s%N)
        "$bin" "$@" > /dev/null
        end=$(date +%s%N)
        ms=$(( (end - start) / 1000000 ))
        (( ms < best )) && best=$ms
    done
    echo "$best"
}

compile() { # compile <src.rg> <out> -> compiles with $RGC
    "$RGC" "$1" -o "$2" > /dev/null
}

# --- build all binaries -----------------------------------------------------
for b in fib sumloop floatloop gemm; do
    compile "$ROOT/benchmarks/src/$b.rg" "$WORK/${b}_rgc"
    g++ -O2 -std=c++17 "$ROOT/benchmarks/src/$b.cpp" -o "$WORK/${b}_gxx"
    if [ -n "$CLANG" ]; then
        "$CLANG" -O2 -std=c++17 "$ROOT/benchmarks/src/$b.cpp" -o "$WORK/${b}_clang" -lstdc++
    fi
done

# --- run and time ------------------------------------------------------------
r_fib=$(run_best "$WORK/fib_rgc")
g_fib=$(run_best "$WORK/fib_gxx")
c_fib=$([ -n "$CLANG" ] && run_best "$WORK/fib_clang" || echo "-")

r_sum=$(run_best "$WORK/sumloop_rgc")
g_sum=$(run_best "$WORK/sumloop_gxx")
c_sum=$([ -n "$CLANG" ] && run_best "$WORK/sumloop_clang" || echo "-")

r_flt=$(run_best "$WORK/floatloop_rgc")
g_flt=$(run_best "$WORK/floatloop_gxx")
c_flt=$([ -n "$CLANG" ] && run_best "$WORK/floatloop_clang" || echo "-")

r_gemm=$(run_best "$WORK/gemm_rgc")
g_gemm=$(run_best "$WORK/gemm_gxx")
c_gemm=$([ -n "$CLANG" ] && run_best "$WORK/gemm_clang" || echo "-")

# --- report -----------------------------------------------------------------
printf '%-24s %12s %12s %12s\n' 'benchmark' 'RGC (-O2)' 'g++ -O2' 'clang -O2'
printf '%-24s %12s %12s %12s\n' '----------' '---------' '--------' '--------'
printf '%-24s %9d ms %9d ms %9s ms\n' 'fib(38)' "$r_fib" "$g_fib" "$c_fib"
printf '%-24s %9d ms %9d ms %9s ms\n' 'sumloop 1e9' "$r_sum" "$g_sum" "$c_sum"
printf '%-24s %9d ms %9d ms %9s ms\n' 'floatloop 5e8' "$r_flt" "$g_flt" "$c_flt"
printf '%-24s %9d ms %9d ms %9s ms\n' 'gemm 512x512' "$r_gemm" "$g_gemm" "$c_gemm"

echo
echo "RGC compiler: $RGC"
if [ -n "$CLANG" ]; then echo "clang: $CLANG"; fi
echo "Best of 3 wall-clock runs. See benchmarks/README.md for details."