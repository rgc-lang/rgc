# RGC standard library: math
#
# Note: math functions (abs/min/max/sqrt/pow/floor/ceil) are compiler builtins,
# called via `math.sqrt(x)` or with the prefix omitted (`sqrt(x)`); they need no definitions here.
# This file keeps an example of a module-level extension function: a module's public function takes priority over a same-named builtin.

public def add(a: int, b: int) -> int {
    return a + b
}
