# setup-llvm.ps1 — install a pinned prebuilt LLVM on Windows for RGC builds.
#
# Uses the official MSVC-ABI archives (x86_64/aarch64-pc-windows-msvc) so the
# exact LLVM version is pinned and any preinstalled LLVM is left untouched.
# The archive is cached; extraction goes to a versioned directory.
#
# Writes LLVM_BIN / LLVM_DIR to $env:GITHUB_ENV for later workflow steps.
#
# Environment:
#   LLVM_VERSION  (default: 23.1.4)
$ErrorActionPreference = "Stop"

$LLVMVersion = if ($env:LLVM_VERSION) { $env:LLVM_VERSION } else { "23.1.4" }
$ArchName = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    "aarch64-pc-windows-msvc"
} else {
    "x86_64-pc-windows-msvc"
}
$Asset = "clang+llvm-$LLVMVersion-$ArchName.tar.xz"
$Url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVMVersion/$Asset"
$CacheRoot = Join-Path $env:LOCALAPPDATA "rgc-llvm"
$ArchiveDir = Join-Path $CacheRoot "archives"
$Archive = Join-Path $ArchiveDir $Asset
$Dest = Join-Path $CacheRoot "$LLVMVersion-$ArchName"

New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
if (-not (Test-Path $Archive)) {
    Write-Host "==> downloading LLVM $LLVMVersion ($ArchName)"
    Invoke-WebRequest -Uri $Url -OutFile $Archive
} else {
    Write-Host "==> using cached LLVM archive $Archive"
}

$Config = Join-Path $Dest "lib\cmake\llvm\LLVMConfig.cmake"
if (-not (Test-Path $Config)) {
    Write-Host "==> extracting LLVM $LLVMVersion to $Dest"
    Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    tar -xf $Archive -C $Dest --strip-components=1
    if ($LASTEXITCODE -ne 0) {
        throw "failed to extract $Archive"
    }
}
if (-not (Test-Path $Config)) {
    throw "LLVMConfig.cmake not found in $Dest"
}

$LLVM_BIN = Join-Path $Dest "bin"
$LLVM_DIR = Join-Path $Dest "lib\cmake\llvm"
Write-Host "==> LLVM_BIN=$LLVM_BIN"
Write-Host "==> LLVM_DIR=$LLVM_DIR"

if ($env:GITHUB_ENV) {
    "LLVM_BIN=$LLVM_BIN" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "LLVM_DIR=$LLVM_DIR" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
} else {
    Write-Host "set LLVM_BIN=$LLVM_BIN and LLVM_DIR=$LLVM_DIR in your environment"
}
