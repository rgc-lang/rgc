# pyrig — RGC's official Python binding framework
#
# Modeled after the pybind11 experience, implemented directly on the CPython C API:
# RGC functions are wrapped by the pyrig builder into a CPython extension module (.so) that Python can import directly.
#
# Usage (RGC side):
#   import pyrig
#
#   public def add(a: int, b: int) -> int {
#       return a + b
#   }
#
#   # pybind11 equivalent of m.def("add", &add)
#   pyrig.export("add")
#
# Building (generates the CPython C API glue and links a shared library):
#   python3 pyrig/pyrig.py build examples/pyrig_demo.rg -n demo -o build/
#
# pyrig.export is only a compile-time marker: top-level statements do not participate in code generation;
# the pyrig builder statically scans them and generates the PyMethodDef / PyInit_<name> glue.

# Binding marker: declares that a function is exported as a Python-callable object.
#   export("py name")                  -> exports the RGC function with the same name
#   export("py name", "rgc fn name")   -> exports the given RGC function
# It is a no-op at runtime.
public def export(name: str) -> None {
    return
}

public def export_as(name: str, fn: str) -> None {
    return
}

public def version() -> str {
    return "0.3.0"
}
