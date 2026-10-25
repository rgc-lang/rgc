# str_concat.rg — string concatenation results and the buffers behind them.
#
# A chained `a + b + c` mallocs one buffer per `+`. Only the outermost one escapes; the
# intermediates are dead once their bytes have been copied out, so codegen frees them. Freeing
# one that is still reachable shows up as a wrong value or a crash, not as a diagnostic, so every
# case below checks the resulting text rather than the allocation behaviour.

def shout(s: str) -> str {
    return s + "!"
}

def wrap(s: str) -> str {
    return "<" + s + ">"
}

public def test_left_nested_chain() -> int {
    name = "rgc"
    got = "hello, " + name + "!"
    if got != "hello, rgc!" {
        print("failed left-nested chain: got " + got)
        return 1
    }
    return 0
}

public def test_right_nested_chain() -> int {
    got = "a" + ("b" + "c")
    if got != "abc" {
        print("failed right-nested chain: got " + got)
        return 1
    }
    return 0
}

public def test_long_chain() -> int {
    got = "1" + "2" + "3" + "4" + "5" + "6"
    if got != "123456" {
        print("failed long chain: got " + got)
        return 1
    }
    return 0
}

public def test_chain_of_calls() -> int {
    # Both operands are themselves concatenations, and each call result feeds a further one.
    got = shout("a") + shout("b") + wrap("c")
    if got != "a!b!<c>" {
        print("failed chain of calls: got " + got)
        return 1
    }
    return 0
}

public def test_accumulate_in_loop() -> int {
    # `s = s + x` reads a live variable, which must survive the concatenation that consumes it.
    s = ""
    i = 0
    while i < 40 {
        s = s + to_string(i % 10)
        i = i + 1
    }
    if s.len() != 40 {
        print("failed accumulate length: got " + to_string(s.len()))
        return 1
    }
    j = 0
    while j < 40 {
        if s.slice(j, j + 1) != to_string(j % 10) {
            print("failed accumulate at " + to_string(j) + ": got " + s)
            return 1
        }
        j = j + 1
    }
    return 0
}

public def test_chain_in_loop() -> int {
    # A fresh chain per iteration: reused chunks carry the previous iteration's bytes, so a
    # freed-but-still-read buffer would produce the wrong text rather than a crash. The
    # expectation is accumulated one step at a time, where every left operand is a live variable
    # and codegen therefore frees nothing.
    i = 0
    while i < 200 {
        got = "n" + to_string(i) + "-" + to_string(i * 2) + "|"
        want = "n"
        want = want + to_string(i)
        want = want + "-"
        want = want + to_string(i * 2)
        want = want + "|"
        if got != want {
            print("failed chain in loop at " + to_string(i) + ": got " + got)
            return 1
        }
        i = i + 1
    }
    return 0
}

public def test_chain_as_argument() -> int {
    got = wrap("x" + "y" + "z")
    if got != "<xyz>" {
        print("failed chain as argument: got " + got)
        return 1
    }
    return 0
}

public def test_returned_chain() -> int {
    # The outermost buffer escapes to the caller, so it must not be freed by the callee.
    got = shout("a" + "b")
    if got != "ab!" {
        print("failed returned chain: got " + got)
        return 1
    }
    if got.len() != 3 {
        print("failed returned chain length: got " + to_string(got.len()))
        return 1
    }
    return 0
}
