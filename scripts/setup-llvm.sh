#!/usr/bin/env bash
# setup-llvm.sh — download and set up a prebuilt LLVM for the current platform.
#
# Modeled on rustc's `download-ci-llvm`: instead of asking developers to install
# LLVM by hand, the build workflow downloads a prebuilt LLVM automatically and
# exposes LLVM_BIN / LLVM_DIR for RGC's build scripts (src/build.sh and
# src/tools/llvm-shim.sh).
#
# Platform support:
#   linux-x64      -> official LLVM-<ver>-Linux-X64.tar.xz
#   linux-arm64    -> official LLVM-<ver>-Linux-ARM64.tar.xz
#   macos-arm64    -> official LLVM-<ver>-macOS-ARM64.tar.xz
#   macos-x64      -> Homebrew `brew install llvm` (no official prebuilt)
#   windows-x64    -> use setup-llvm.ps1 instead
#
# Usage (CI):
#   eval "$(bash scripts/setup-llvm.sh)"
#   echo "LLVM_BIN=$LLVM_BIN" >> "$GITHUB_ENV"
#   echo "LLVM_DIR=$LLVM_DIR" >> "$GITHUB_ENV"
#
# Environment:
#   LLVM_VERSION  (default: 23.1.4)
#   LLVM_CACHE    (default: ~/.cache/rgc-llvm)
#   LLVM_ARCHIVE_CACHE (default: $LLVM_CACHE/archives; kept for CI caching)
#   LLVM_BIN / LLVM_DIR already set and valid -> used as-is
set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:-23.1.4}"
CACHE_DIR="${LLVM_CACHE:-$HOME/.cache/rgc-llvm}"
ARCHIVE_DIR="${LLVM_ARCHIVE_CACHE:-$CACHE_DIR/archives}"
RELEASE_BASE="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}"

# Use a pre-configured LLVM only when it is the pinned version.
if [ -n "${LLVM_BIN:-}" ] && [ -x "$LLVM_BIN/llvm-config" ]; then
  have="$("$LLVM_BIN/llvm-config" --version)"
  if [ "$have" != "$LLVM_VERSION" ]; then
    echo "error: expected LLVM $LLVM_VERSION, found $have in $LLVM_BIN" >&2
    exit 1
  fi
  LLVM_DIR="${LLVM_DIR:-$(cd "$LLVM_BIN/.." && pwd)/../lib/cmake/llvm}"
  echo "export LLVM_BIN='$LLVM_BIN'"
  echo "export LLVM_DIR='$LLVM_DIR'"
  exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux*) platform="linux" ;;
  Darwin*) platform="macos" ;;
  *)
    echo "error: unsupported OS: $os (Linux and macOS only; Windows uses setup-llvm.ps1)" >&2
    exit 1
    ;;
esac
case "$arch" in
  x86_64 | amd64) arch="x64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *)
    echo "error: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

# macOS x64 has no official prebuilt LLVM; build the pinned release from source.
if [ "$platform" = "macos" ] && [ "$arch" = "x64" ]; then
  DEST="$CACHE_DIR/$LLVM_VERSION/$platform-$arch"
  MARKER="$DEST/.rgc-llvm-$LLVM_VERSION-complete"
  if [ ! -f "$MARKER" ]; then
    mkdir -p "$ARCHIVE_DIR" "$CACHE_DIR"
    SRC_ARCHIVE="$ARCHIVE_DIR/llvm-project-${LLVM_VERSION}.src.tar.xz"
    if [ ! -f "$SRC_ARCHIVE" ]; then
      echo "==> downloading LLVM ${LLVM_VERSION} source" >&2
      tmp_download="$ARCHIVE_DIR/.tmp-llvm-project-${LLVM_VERSION}.tar.xz.$$"
      rm -f "$tmp_download"
      curl -fL "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz" -o "$tmp_download"
      mv "$tmp_download" "$SRC_ARCHIVE"
    else
      echo "==> using cached LLVM source ${SRC_ARCHIVE}" >&2
    fi
    SRC_DIR="$CACHE_DIR/src-$LLVM_VERSION"
    BUILD_DIR="$CACHE_DIR/build-$LLVM_VERSION-macos-x64"
    rm -rf "$SRC_DIR" "$BUILD_DIR"
    mkdir -p "$SRC_DIR" "$BUILD_DIR"
    echo "==> extracting LLVM ${LLVM_VERSION} source" >&2
    tar xJf "$SRC_ARCHIVE" -C "$SRC_DIR" --strip-components=1
    GENERATOR=()
    if command -v ninja >/dev/null 2>&1; then
      GENERATOR=(-G Ninja)
    fi
    echo "==> building LLVM ${LLVM_VERSION} for macOS x64 (X86 only)" >&2
    cmake -S "$SRC_DIR/llvm" -B "$BUILD_DIR" ${GENERATOR[@]+"${GENERATOR[@]}"} \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$DEST" \
      -DLLVM_ENABLE_PROJECTS= \
      -DLLVM_TARGETS_TO_BUILD=X86 \
      -DLLVM_ENABLE_ASSERTIONS=OFF \
      -DLLVM_BUILD_LLVM_DYLIB=OFF \
      -DLLVM_LINK_LLVM_DYLIB=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF \
      -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DLLVM_ENABLE_BINDINGS=OFF >&2
    cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.ncpu)" >&2
    cmake --install "$BUILD_DIR" >&2
    touch "$MARKER"
    rm -rf "$SRC_DIR" "$BUILD_DIR"
  fi
  LLVM_BIN="$DEST/bin"
  LLVM_DIR="$DEST/lib/cmake/llvm"
  have="$("$LLVM_BIN/llvm-config" --version)"
  if [ "$have" != "$LLVM_VERSION" ]; then
    echo "error: expected LLVM $LLVM_VERSION, built $have" >&2
    exit 1
  fi
  echo "export LLVM_BIN='$LLVM_BIN'"
  echo "export LLVM_DIR='$LLVM_DIR'"
  exit 0
fi

case "$platform-$arch" in
  linux-x64)    asset="LLVM-${LLVM_VERSION}-Linux-X64.tar.xz" ;;
  linux-arm64)  asset="LLVM-${LLVM_VERSION}-Linux-ARM64.tar.xz" ;;
  macos-arm64)  asset="LLVM-${LLVM_VERSION}-macOS-ARM64.tar.xz" ;;
  *)
    echo "error: unsupported platform: $platform-$arch" >&2
    exit 1
    ;;
esac

DEST="$CACHE_DIR/$LLVM_VERSION/$platform-$arch"
ARCHIVE="$ARCHIVE_DIR/$asset"
if [ ! -x "$DEST/bin/llvm-config" ]; then
  mkdir -p "$ARCHIVE_DIR" "$CACHE_DIR"
  if [ ! -f "$ARCHIVE" ]; then
    echo "==> downloading LLVM ${LLVM_VERSION} (${platform}-${arch})" >&2
    tmp_download="$ARCHIVE_DIR/.tmp-$asset.$$"
    rm -f "$tmp_download"
    curl -fL "${RELEASE_BASE}/${asset}" -o "$tmp_download"
    mv "$tmp_download" "$ARCHIVE"
  else
    echo "==> using cached LLVM archive ${ARCHIVE}" >&2
  fi
  tmp="$CACHE_DIR/.tmp-llvm-$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  tar xJf "$ARCHIVE" -C "$tmp"
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [ -z "$extracted" ] || [ ! -d "$extracted" ]; then
    echo "error: failed to extract $asset" >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  mv "$extracted" "$DEST"
  rm -rf "$tmp"
fi

LLVM_BIN="$DEST/bin"
LLVM_DIR="$DEST/lib/cmake/llvm"
have="$("$LLVM_BIN/llvm-config" --version)"
if [ "$have" != "$LLVM_VERSION" ]; then
  echo "error: expected LLVM $LLVM_VERSION, found $have in $LLVM_BIN" >&2
  exit 1
fi
echo "export LLVM_BIN='$LLVM_BIN'"
echo "export LLVM_DIR='$LLVM_DIR'"