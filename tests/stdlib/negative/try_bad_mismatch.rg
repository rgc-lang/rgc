def g() -> Result[int, int] {
    return Result[int, int].Err(1)
}

def f() -> Result[int, str] {
    x = g()?
    return Result[int, str].Ok(x)
}

def main() {
    pass
}
