# pyrgc example: export RGC functions as a CPython extension module
#
# Building (modeled after PyO3/maturin; after pip install -e pyrgc/):
#   pyrgc build examples/pyrgc_demo.rg -n pyrgc_demo -o build/pyrgc
#   python3 -c "import sys; sys.path.insert(0, 'build/pyrgc'); \
#               import pyrgc_demo; print(pyrgc_demo.add(3, 4))"

import pyrgc

public def add(a: int, b: int) -> int {
    return a + b
}

public def greet(name: str) -> str {
    return "hello, " + name + "!"
}

public def is_even(n: int) -> bool {
    return n % 2 == 0
}

public def dist(ax: float, ay: float, bx: float, by: float) -> float {
    dx = ax - bx
    dy = ay - by
    return sqrt(dx * dx + dy * dy)
}

public def say_hi() -> None {
    puts("hi from RGC")
}

# pybind11: PYBIND11_MODULE(pyrgc_demo, m) { m.def("add", &add); ... }
pyrgc.export("add")
pyrgc.export("greet")
pyrgc.export("is_even")
pyrgc.export("dist")
pyrgc.export("say_hi")

# extern def and pyrgc can be mixed: puts comes from libc
extern def puts(s: str) -> int
