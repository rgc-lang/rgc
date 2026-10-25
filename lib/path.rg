# RGC standard library: path
#
# Pure string path utilities (POSIX style, / separated).

public def is_absolute(p: str) -> bool {
    return p.len() > 0 and p.char_at(0) == 47
}

def last_slash(p: str) -> int {
    i = p.len() - 1
    while i >= 0 {
        if p.char_at(i) == 47 {
            return i
        }
        i = i - 1
    }
    return -1
}

public def join(a: str, b: str) -> str {
    if a.len() == 0 {
        return b
    }
    if b.len() == 0 {
        return a
    }
    if a.char_at(a.len() - 1) == 47 {
        return a + b
    }
    if b.char_at(0) == 47 {
        return a + b
    }
    return a + "/" + b
}

public def basename(p: str) -> str {
    if p.len() == 0 {
        return ""
    }
    end = p.len()
    while end > 1 and p.char_at(end - 1) == 47 {
        end = end - 1
    }
    i = last_slash(p)
    if i < 0 {
        return p.slice(0, end)
    }
    if i + 1 >= end {
        return "/"
    }
    return p.slice(i + 1, end)
}

public def dirname(p: str) -> str {
    i = last_slash(p)
    if i < 0 {
        return "."
    }
    if i == 0 {
        return "/"
    }
    end = i
    while end > 1 and p.char_at(end - 1) == 47 {
        end = end - 1
    }
    return p.slice(0, end)
}

public def extension(p: str) -> str {
    i = last_slash(p)
    dot = p.len() - 1
    while dot > i {
        if p.char_at(dot) == 46 {
            return p.slice(dot + 1, p.len())
        }
        dot = dot - 1
    }
    return ""
}

public def stem(p: str) -> str {
    i = last_slash(p)
    dot = p.len() - 1
    while dot > i {
        if p.char_at(dot) == 46 {
            return p.slice(0, dot)
        }
        dot = dot - 1
    }
    return p
}
