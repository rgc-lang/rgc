#!/usr/bin/env python3
"""Package an RGC toolchain component into per-OS release archives.

This script is used by the release CI workflow (`.github/workflows/release.yml`)
and can also be run locally to verify packaging. It is intentionally
self-contained so each repository (rgc, rack) can own a copy.

For the `rgc` component the archive contains the compiler binary plus the
standard library source modules (`lib/`). For `rack` it contains just the
package-manager binary.

Usage:
  python3 scripts/package-release.py \\
      --component rgc \\
      --os linux --arch x64 \\
      --bin build/rgc \\
      --lib-dir lib \\
      --out dist

Produces, for example:
  dist/rgc-linux-x64.tar.gz
  dist/rack-linux-x64.tar.gz      # when --component rack

Windows output uses `.zip` and `<component>.exe`; other platforms use
`.tar.gz` with the binary named `<component>` at the archive root
(the installers support both root-level and `bin/` layout).
"""

import argparse
import sys
import tarfile
import zipfile
from pathlib import Path

COMPONENTS = ("rgc", "rack")
OS_NAMES = ("linux", "macos", "windows")
ARCH_NAMES = ("x64", "arm64")


def archive_stem(component: str, os_name: str, arch: str) -> str:
    return f"{component}-{os_name}-{arch}"


def binary_arcname(component: str, os_name: str) -> str:
    return f"{component}.exe" if os_name == "windows" else component


def add_file_to_tar(tf: tarfile.TarFile, src: Path, arcname: str) -> None:
    info = tf.gettarinfo(str(src), arcname=arcname)
    # Make the binary executable in the archive.
    if info.isfile():
        info.mode = 0o755
    with open(src, "rb") as f:
        tf.addfile(info, f)


def write_tar_gz(path: Path, files: list[tuple[Path, str]]) -> None:
    with tarfile.open(path, "w:gz") as tf:
        for src, arc in files:
            if src.is_dir():
                tf.add(str(src), arcname=arc, recursive=True, filter=lambda i: i)
            else:
                add_file_to_tar(tf, src, arc)


def write_zip(path: Path, files: list[tuple[Path, str]]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for src, arc in files:
            if src.is_dir():
                for p in sorted(src.rglob("*")):
                    if p.is_file():
                        zf.write(str(p), f"{arc}/{p.relative_to(src)}")
            else:
                zf.write(str(src), arc)


def package(component: str, os_name: str, arch: str, bin_path: Path,
            lib_dir: Path | None, out: Path) -> Path:
    if component not in COMPONENTS:
        sys.exit(f"error: --component must be one of {', '.join(COMPONENTS)}")
    if not bin_path.is_file():
        sys.exit(f"error: binary not found: {bin_path}")

    out.mkdir(parents=True, exist_ok=True)
    stem = archive_stem(component, os_name, arch)
    ext = "zip" if os_name == "windows" else "tar.gz"
    path = out / f"{stem}.{ext}"

    files = [(bin_path, binary_arcname(component, os_name))]
    if component == "rgc" and lib_dir is not None:
        if not lib_dir.is_dir():
            sys.exit(f"error: lib directory not found: {lib_dir}")
        files.append((lib_dir, "lib"))

    if os_name == "windows":
        write_zip(path, files)
    else:
        write_tar_gz(path, files)
    print(f"wrote {path}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", required=True, choices=COMPONENTS)
    parser.add_argument("--os", required=True, choices=OS_NAMES)
    parser.add_argument("--arch", required=True, choices=ARCH_NAMES)
    parser.add_argument("--bin", required=True, type=Path, help="Path to the component binary")
    parser.add_argument("--lib-dir", type=Path, default=None,
                       help="Path to the standard library directory (rgc only)")
    parser.add_argument("--out", type=Path, default=Path("dist"))
    args = parser.parse_args()

    package(args.component, args.os, args.arch, args.bin, args.lib_dir, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())