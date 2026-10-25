# unitdemo.rg — unit-test layer demo for `rack test`: a file without an entry point but with
# `public def test_*() -> int` functions has each function run in its own process
# (return 0 = pass, nonzero = fail). Only public test_* functions are dispatched; plain
# helpers are ignored. Imports resolve as usual (stdlib via the compiler's lib dir).

import string

def expect_str(name: str, got: str, want: str) -> int {
    if got == want {
        return 0
    }
    print("failed " + name + ": got '" + got + "', want '" + want + "'")
    return 1
}

def expect_int(name: str, got: int, want: int) -> int {
    if got == want {
        return 0
    }
    print("failed " + name + ": got " + to_string(got) + ", want " + to_string(want))
    return 1
}

public def test_trim() -> int {
    return expect_str("trim", string.trim("   hello world  "), "hello world")
}

public def test_repeat_replace() -> int {
    rc = expect_str("repeat", string.repeat("ab", 3), "ababab")
    if rc != 0 {
        return rc
    }
    return expect_str("replace_all", string.replace("a-b-a", "a", "x"), "x-b-x")
}

public def test_find_rfind() -> int {
    rc = expect_int("find", string.find("hello world", "o"), 4)
    if rc != 0 {
        return rc
    }
    rc = expect_int("rfind", string.rfind("hello world", "o"), 7)
    if rc != 0 {
        return rc
    }
    return expect_int("find_missing", string.find("hello", "z"), -1)
}

public def test_lines() -> int {
    ls = string.lines("alpha\nbeta\ngamma")
    rc = expect_int("lines_count", ls.len(), 3)
    if rc != 0 {
        return rc
    }
    return expect_str("lines_middle", ls.get(1), "beta")
}

public def test_case() -> int {
    rc = expect_str("to_upper", string.to_upper("MixEd"), "MIXED")
    if rc != 0 {
        return rc
    }
    return expect_str("to_lower", string.to_lower("MixEd"), "mixed")
}

public def test_compare_pad() -> int {
    rc = expect_int("compare_lt", string.compare("apple", "banana"), -1)
    if rc != 0 {
        return rc
    }
    rc = expect_int("compare_eq", string.compare("same", "same"), 0)
    if rc != 0 {
        return rc
    }
    return expect_str("pad_left", string.pad_left("7", 3, "0"), "007")
}
