#!/usr/bin/env bash
# RGC build script — stage1 is managed by rack
#
#   1. Locate the rgc compiler used to build the current sources
#      (RGC_BOOTSTRAP, or rgc on PATH)
#   2. Bootstrap rack when it is missing or its source is newer
#   3. rack build three stages: rgc1 -> rgc2 -> rgc3
#   4. Verify the rgc2/rgc3 self-IR fixed point, smoke test, and install build/rgc
#
# Every step is an ordinary rack project build: src/rack.toml describes stage1,
# [build].prebuild compiles the embedded-LLVM shim, and link-args-file supplies the link arguments.
#
# Usage: ./build.sh            (run from the src/ directory)
#        RGC_BOOTSTRAP=/path/to/rgc ./build.sh

set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR=build

EXE=""
if [ "${OS:-}" = "Windows_NT" ]; then
    EXE=".exe"
    host_arch="$(uname -m)"
    if [ "${PROCESSOR_ARCHITECTURE:-}" = "ARM64" ] || [ "$host_arch" = "aarch64" ] || [ "$host_arch" = "arm64" ]; then
        # The ARM64 toolchain is Ninja + clang (via the CLANGARM64 gcc wrappers),
        # using the GNU-ABI LLVM libraries from MSYS2.
        export CC="${CC:-gcc}"
        export CXX="${CXX:-g++}"
    fi
fi

BOOTSTRAP="${RGC_BOOTSTRAP:-$(command -v rgc || true)}"
if [ -z "$BOOTSTRAP" ] || [ ! -x "$BOOTSTRAP" ]; then
    echo "error: no rgc compiler found; install a released rgc or set RGC_BOOTSTRAP" >&2
    exit 1
fi
BOOTSTRAP="$(cd "$(dirname "$BOOTSTRAP")" && pwd)/$(basename "$BOOTSTRAP")"

LLVM_BIN="${LLVM_BIN:-/home/bluemoon/llvm/LLVM-23.1.4-Linux-X64/bin}"
RACK="${RACK:-../rack/target/bin/rack$EXE}"
RACK_PROJECT="$(cd "$(dirname "$RACK")/../.." 2>/dev/null && pwd || true)"
export LLVM_BIN
export PATH="$LLVM_BIN:$PATH"

mkdir -p "$BUILD_DIR"

# rack itself is an RGC project; bootstrap it when missing or when its source is newer than the binary.
NEED_RACK=0
if [ ! -x "$RACK" ]; then
    NEED_RACK=1
elif [ -n "$RACK_PROJECT" ] && find "$RACK_PROJECT/src" -newer "$RACK" -print -quit | grep -q .; then
    NEED_RACK=1
fi
if [ "$NEED_RACK" = 1 ]; then
    echo "==> bootstrapping rack"
    (cd "$RACK_PROJECT" && RGC="$BOOTSTRAP" ./tests/bootstrap.sh)
    if [ ! -x "$RACK" ]; then
        RACK="$RACK_PROJECT/target/bin/rack$EXE"
    fi
fi
RACK="$(cd "$(dirname "$RACK")" && pwd)/$(basename "$RACK")"

# Build one stage with rack; the compiler is selected by the RGC environment variable.
build_stage() { # <n> <compiler>
    echo "==> stage$1: rack build (RGC=$2)"
    RGC="$2" "$RACK" build
    cp "target/bin/rgc$EXE" "$BUILD_DIR/rgc$1$EXE"
}

build_stage 1 "$BOOTSTRAP"
build_stage 2 "$PWD/$BUILD_DIR/rgc1$EXE"
build_stage 3 "$PWD/$BUILD_DIR/rgc2$EXE"

echo "==> generating stage2/stage3 self IR and checking consistency"
"$BUILD_DIR/rgc1$EXE" src/main.rg --emit-llvm -o "$BUILD_DIR/rgc2.ll"
"$BUILD_DIR/rgc2$EXE" src/main.rg --emit-llvm -o "$BUILD_DIR/rgc3.ll"
if ! cmp -s "$BUILD_DIR/rgc2.ll" "$BUILD_DIR/rgc3.ll"; then
    echo "error: rgc2/rgc3 IR mismatch" >&2
    exit 1
fi

echo "==> smoke test: rgc3 compiles and runs hello.rg"
"$BUILD_DIR/rgc3$EXE" ../examples/hello.rg -o "$BUILD_DIR/hello$EXE"
"$BUILD_DIR/hello$EXE" > "$BUILD_DIR/hello.out"
cat "$BUILD_DIR/hello.out"
rm -f "$BUILD_DIR/hello$EXE"

mkdir -p ../build
cp "$BUILD_DIR/rgc3$EXE" "../build/rgc$EXE"

echo ""
echo "build complete (stage1 managed by rack):"
ls -lh "$BUILD_DIR"/rgc1"$EXE" "$BUILD_DIR"/rgc2"$EXE" "$BUILD_DIR"/rgc3"$EXE"
echo "stage1 installed: build/rgc$EXE"
