# _fixture.rg — inputs for the exports suite. Not a test case itself: no `def main` and no
# `test_*` functions, so the runner skips it and the suite compiles it explicitly.
#
# Every function here pins one rule of the str-return ownership analysis in src/exports.rg.

public def lit() -> str {
    return "hello"
}

public def param(s: str) -> str {
    return s
}

public def concat(s: str) -> str {
    return "x" + s
}

public def via_local(s: str) -> str {
    msg = "x" + s
    return msg
}

public def trailing(s: str) -> str {
    "x" + s
}

# Both paths allocate, so the caller may free even though the value comes from a branch.
public def branch_owned(s: str) -> str {
    if s.len() > 0 {
        return "a" + s
    } else {
        return "b" + s
    }
}

public def branch_mixed(s: str) -> str {
    if s.len() > 0 {
        return s
    } else {
        return "b" + s
    }
}

public def via_call(s: str) -> str {
    return to_string(s.len())
}

public def reassigned(s: str) -> str {
    msg = s
    msg = msg + "!"
    return msg
}

public def scalars(a: int, b: float, c: bool) -> int {
    return a
}

def priv(s: str) -> str {
    return "p" + s
}

# `export` is orthogonal to `public`: the first is visibility to a host runtime's binding
# generator, the second is visibility to other RGC modules. Either can stand alone.
export def exported_only(a: int) -> int {
    return a
}

public export def exported_public(a: int) -> int {
    return a
}
