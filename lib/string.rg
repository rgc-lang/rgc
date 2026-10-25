# RGC standard library: string
#
# Usage: import string, then call via qualified names like string.trim(s).
# All functions depend only on the compiler's built-in str methods and introduce no new runtime.

public def is_empty(s: str) -> bool {
    return s.len() == 0
}

public def is_digit(s: str) -> bool {
    if s.len() == 0 {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c < 48 or c > 57 {
            return False
        }
        i = i + 1
    }
    return True
}

def is_space(c: int) -> bool {
    return c == 32 or c == 9 or c == 10 or c == 13
}

public def trim(s: str) -> str {
    n = s.len()
    start = 0
    while start < n {
        if not is_space(s.char_at(start)) {
            break
        }
        start = start + 1
    }
    end = n
    while end > start {
        if not is_space(s.char_at(end - 1)) {
            break
        }
        end = end - 1
    }
    return s.slice(start, end)
}

public def ltrim(s: str) -> str {
    n = s.len()
    start = 0
    while start < n {
        if not is_space(s.char_at(start)) {
            break
        }
        start = start + 1
    }
    return s.slice(start, n)
}

public def rtrim(s: str) -> str {
    end = s.len()
    while end > 0 {
        if not is_space(s.char_at(end - 1)) {
            break
        }
        end = end - 1
    }
    return s.slice(0, end)
}

public def find(s: str, sub: str) -> int {
    if sub.len() == 0 {
        return 0
    }
    i = 0
    while i + sub.len() <= s.len() {
        if s.slice(i, i + sub.len()) == sub {
            return i
        }
        i = i + 1
    }
    return -1
}

public def rfind(s: str, sub: str) -> int {
    if sub.len() == 0 {
        return s.len()
    }
    i = s.len() - sub.len()
    while i >= 0 {
        if s.slice(i, i + sub.len()) == sub {
            return i
        }
        i = i - 1
    }
    return -1
}

# Lexicographic comparison: a < b -> -1, equal -> 0, a > b -> 1.
public def compare(a: str, b: str) -> int {
    n = a.len()
    if b.len() < n {
        n = b.len()
    }
    i = 0
    while i < n {
        ca = a.char_at(i)
        cb = b.char_at(i)
        if ca < cb {
            return -1
        }
        if ca > cb {
            return 1
        }
        i = i + 1
    }
    if a.len() < b.len() {
        return -1
    }
    if a.len() > b.len() {
        return 1
    }
    return 0
}

public def repeat(s: str, n: int) -> str {
    out = ""
    i = 0
    while i < n {
        out = out + s
        i = i + 1
    }
    return out
}

public def replace(s: str, old: str, repl: str) -> str {
    if old.len() == 0 {
        return s
    }
    # Delegate to the builtin method: split() drops trailing empty parts (Java semantics),
    # so a split+join reimplementation loses the tail when s ends with `old`.
    return s.replace(old, repl)
}

public def lines(s: str) -> List[str] {
    raw = s.split("\n")
    out = List[str]()
    i = 0
    while i < raw.len() {
        ln = raw.get(i)
        if ln.len() > 0 and ln.char_at(ln.len() - 1) == 13 {
            out.push(ln.slice(0, ln.len() - 1))
        } else {
            out.push(ln)
        }
        i = i + 1
    }
    return out
}

public def split_whitespace(s: str) -> List[str] {
    out = List[str]()
    start = -1
    i = 0
    while i < s.len() {
        if is_space(s.char_at(i)) {
            if start >= 0 {
                out.push(s.slice(start, i))
                start = -1
            }
        } elif start < 0 {
            start = i
        }
        i = i + 1
    }
    if start >= 0 {
        out.push(s.slice(start, s.len()))
    }
    return out
}

public def to_lower(s: str) -> str {
    lower = "abcdefghijklmnopqrstuvwxyz"
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c >= 65 and c <= 90 {
            out = out + lower.slice(c - 65, c - 64)
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out
}

public def to_upper(s: str) -> str {
    upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c >= 97 and c <= 122 {
            out = out + upper.slice(c - 97, c - 96)
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out
}

public def pad_left(s: str, width: int, ch: str) -> str {
    fill = ch
    if fill.len() == 0 {
        fill = " "
    }
    out = s
    while out.len() < width {
        out = fill + out
    }
    return out
}

public def pad_right(s: str, width: int, ch: str) -> str {
    fill = ch
    if fill.len() == 0 {
        fill = " "
    }
    out = s
    while out.len() < width {
        out = out + fill
    }
    return out
}
