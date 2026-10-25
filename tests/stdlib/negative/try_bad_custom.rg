class Point {
    x: int
}

def g() -> Result[Point, str] {
    return Result[Point, str].Err("no")
}

def f() -> Result[Point, str] {
    p = g()?
    return Result[Point, str].Ok(p)
}

def main() {
    pass
}
