# RGC compiler: common utility module
#
# Current C++ compiler limitations:
#   - runtime string `==` compares only pointers; compare content with len+contains instead
#   - List[T]() cannot be written inside generic function bodies; list construction helpers are non-generic functions

import os

# Host OS detection: Windows sets OS=Windows_NT in the process environment.
public def host_is_windows() -> bool {
    v = os.getenv("OS")
    if v.is_nothing() {
        return False
    }
    return str_eq(v.unwrap(), "Windows_NT")
}

# Quote a path for the host shell command line.
public def shell_quote(s: str) -> str {
    if host_is_windows() {
        return "\"" + s + "\""
    }
    return "'" + s + "'"
}

# First line of multi-line command output (drops the trailing CR/LF).
public def first_line(s: str) -> str {
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 10 or c == 13 {
            return s.slice(0, i)
        }
        i = i + 1
    }
    return s
}

# String content equality (same length and mutually contained).
public def str_eq(a: str, b: str) -> bool {
    if a.len() != b.len() {
        return False
    }
    return a.contains(b)
}

# Index of the first occurrence of a substring; -1 when absent.
public def str_find(s: str, sub: str) -> int {
    if sub.len() == 0 {
        return 0
    }
    i = 0
    while i + sub.len() <= s.len() {
        if str_eq(s.slice(i, i + sub.len()), sub) {
            return i
        }
        i = i + 1
    }
    return -1
}

# Index of the last occurrence of a substring; -1 when absent.
public def str_rfind(s: str, sub: str) -> int {
    if sub.len() == 0 {
        return s.len()
    }
    i = s.len() - sub.len()
    while i >= 0 {
        if str_eq(s.slice(i, i + sub.len()), sub) {
            return i
        }
        i = i - 1
    }
    return -1
}

# Module path canonicalization: `net/tcp` -> `net$tcp`.
# The physical symbol prefix of hierarchical modules must replace `/`; otherwise the LLVM identifier is invalid.
public def module_canon(name: str) -> str {
    if str_find(name, "/") < 0 {
        return name
    }
    out = ""
    i = 0
    while i < name.len() {
        c = name.slice(i, i + 1)
        if str_eq(c, "/") {
            out = out + "$"
        } else {
            out = out + c
        }
        i = i + 1
    }
    return out
}

# Trim leading/trailing whitespace (space / tab / CR / LF).
public def trim(s: str) -> str {
    n = s.len()
    start = 0
    while start < n {
        c = s.char_at(start)
        if c != 32 and c != 9 and c != 10 and c != 13 {
            break
        }
        start = start + 1
    }
    end = n
    while end > start {
        c = s.char_at(end - 1)
        if c != 32 and c != 9 and c != 10 and c != 13 {
            break
        }
        end = end - 1
    }
    return s.slice(start, end)
}

# Read a file; returns an empty string on failure (for "absent means continue" cases like module search).
public def read_file_or(path: str) -> str {
    r = read_file(path)
    if r.is_err() {
        return ""
    }
    return r.unwrap()
}
