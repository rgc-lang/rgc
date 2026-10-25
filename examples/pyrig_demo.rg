# pyrig example: export RGC functions as a CPython extension module
#
# Building (modeled after PyO3/maturin; after pip install -e pyrig/):
#   pyrig build examples/pyrig_demo.rg -n pyrig_demo -o build/pyrig
#   python3 -c "import sys; sys.path.insert(0, 'build/pyrig'); \
#               import pyrig_demo; print(pyrig_demo.add(3, 4))"

import pyrig

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

# pybind11: PYBIND11_MODULE(pyrig_demo, m) { m.def("add", &add); ... }
pyrig.export("add")
pyrig.export("greet")
pyrig.export("is_even")
pyrig.export("dist")
pyrig.export("say_hi")

# extern def and pyrig can be mixed: puts comes from libc
extern def puts(s: str) -> int
