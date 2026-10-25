def parse_double(s: str) -> Result[int, str] {
    n = s.to_int()?
    return Result[int, str].Ok(n * 2)
}

def parse_sum(a: str, b: str) -> Result[int, str] {
    total = parse_double(a)? + parse_double(b)?
    return Result[int, str].Ok(total)
}

def first_line(path: str) -> Result[str, str] {
    content = read_file(path)?
    return Result[str, str].Ok(content)
}

def positive(s: str) -> Result[bool, str] {
    n = s.to_int()?
    return Result[bool, str].Ok(n > 0)
}

def half(s: str) -> Result[float, str] {
    f = s.to_float()?
    return Result[float, str].Ok(f / 2.0)
}

def maybe_fail(i: int) -> Result[int, str] {
    if i == 2 {
        return Result[int, str].Err("stop")
    }
    return Result[int, str].Ok(i)
}

def loop_sum() -> Result[int, str] {
    total = 0
    for i in range(4) {
        total = total + maybe_fail(i)?
    }
    return Result[int, str].Ok(total)
}

def fail_int() -> Result[int, int] {
    return Result[int, int].Err(42)
}

def use_int_err() -> Result[int, int] {
    v = fail_int()?
    return Result[int, int].Ok(v + 1)
}

def use_var() -> Result[int, str] {
    r = Result[int, str].Ok(7)
    v = r?
    return Result[int, str].Ok(v + 1)
}

def main() {
    match parse_sum("20", "22") {
        case Ok(v) => print("sum", v)
        case Err(e) => print("sum err", e)
    }
    match parse_sum("20", "x") {
        case Ok(v) => print("bad", v)
        case Err(e) => print("err", e)
    }
    match first_line("/nonexistent-rgc-try-file") {
        case Ok(v) => print("bad", v)
        case Err(e) => print("read", e)
    }
    match positive("3") {
        case Ok(v) => print("bool", v)
        case Err(e) => print("bool err", e)
    }
    match half("5.0") {
        case Ok(v) => print("half", v)
        case Err(e) => print("half err", e)
    }
    match use_int_err() {
        case Ok(v) => print("bad", v)
        case Err(e) => print("int err", e)
    }
    match use_var() {
        case Ok(v) => print("var", v)
        case Err(e) => print("var err", e)
    }
    match loop_sum() {
        case Ok(v) => print("bad", v)
        case Err(e) => print("loop", e)
    }
}
