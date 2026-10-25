# RGC standard library: list
#
# Generic container operations should use the compiler's built-in methods (len/push/pop/get/set/clear);
# this module provides common batch operations for int/str.
# Read-only parameters use @List[T]; use @var List[T] when mutation is needed.

import string

public def sum_ints(xs: @List[int]) -> int {
    total = 0
    i = 0
    while i < xs.len() {
        total = total + xs.get(i)
        i = i + 1
    }
    return total
}

public def min_int(xs: @List[int]) -> int {
    if xs.len() == 0 {
        return 0
    }
    m = xs.get(0)
    i = 1
    while i < xs.len() {
        v = xs.get(i)
        if v < m {
            m = v
        }
        i = i + 1
    }
    return m
}

public def max_int(xs: @List[int]) -> int {
    if xs.len() == 0 {
        return 0
    }
    m = xs.get(0)
    i = 1
    while i < xs.len() {
        v = xs.get(i)
        if v > m {
            m = v
        }
        i = i + 1
    }
    return m
}

public def index_of_int(xs: @List[int], value: int) -> int {
    i = 0
    while i < xs.len() {
        if xs.get(i) == value {
            return i
        }
        i = i + 1
    }
    return -1
}

public def index_of_str(xs: @List[str], value: str) -> int {
    i = 0
    while i < xs.len() {
        if xs.get(i) == value {
            return i
        }
        i = i + 1
    }
    return -1
}

public def sort_ints(xs: @var List[int]) {
    i = 1
    while i < xs.len() {
        v = xs.get(i)
        j = i - 1
        while j >= 0 and xs.get(j) > v {
            xs.set(j + 1, xs.get(j))
            j = j - 1
        }
        xs.set(j + 1, v)
        i = i + 1
    }
}

public def sort_strs(xs: @var List[str]) {
    i = 1
    while i < xs.len() {
        v = xs.get(i)
        j = i - 1
        while j >= 0 and string.compare(xs.get(j), v) > 0 {
            xs.set(j + 1, xs.get(j))
            j = j - 1
        }
        xs.set(j + 1, v)
        i = i + 1
    }
}

public def reverse_ints(xs: @var List[int]) {
    i = 0
    j = xs.len() - 1
    while i < j {
        a = xs.get(i)
        b = xs.get(j)
        xs.set(i, b)
        xs.set(j, a)
        i = i + 1
        j = j - 1
    }
}

public def join_ints(xs: @List[int], sep: str) -> str {
    parts = List[str]()
    i = 0
    while i < xs.len() {
        parts.push(to_string(xs.get(i)))
        i = i + 1
    }
    return sep.join(parts)
}
