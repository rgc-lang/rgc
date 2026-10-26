# pyrgc example: export RGC functions as a CPython extension module
#
# Building (modeled after PyO3/maturin; after pip install -e pyrgc/):
#   pyrgc build examples/pyrgc_demo.rg -n pyrgc_demo -o build/pyrgc
#   python3 -c "import sys; sys.path.insert(0, 'build/pyrgc'); \
#               import pyrgc_demo; print(pyrgc_demo.add(3, 4))"
#
# `export` marks a function for a host runtime's binding generator. It is
# orthogonal to `public` (visibility to other RGC modules); the combined form
# is `public export def`. pyrgc wraps exactly the exported functions and takes
# their signatures from the compiler's --emit-exports metadata.

export def add(a: int, b: int) -> int {
    return a + b
}

export def greet(name: str) -> str {
    return "hello, " + name + "!"
}

export def is_even(n: int) -> bool {
    return n % 2 == 0
}

export def dist(ax: float, ay: float, bx: float, by: float) -> float {
    dx = ax - bx
    dy = ay - by
    return sqrt(dx * dx + dy * dy)
}

export def say_hi() -> None {
    puts("hi from RGC")
}

# No `export`: a plain RGC function must stay out of the extension module.
def scale_internal(n: int) -> int {
    return n * 2
}

# extern def and export def compose: puts comes from libc
extern def puts(s: str) -> int
