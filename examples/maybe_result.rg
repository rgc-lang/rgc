# Standard library: built-in generic enums Maybe[T] / Result[T, E] and their methods

def main() {
    # --- Maybe[int] ---
    a = Maybe[int].Some(42)
    b = Maybe[int].Nothing()
    print("a.is_some    =", a.is_some())
    print("a.is_nothing =", a.is_nothing())
    print("b.is_some    =", b.is_some())
    print("b.is_nothing =", b.is_nothing())
    match a {
        case Some(v) => print("match a:", v)
        case Nothing => print("a is nothing")
    }
    print("a.unwrap()   =", a.unwrap())

    # Pattern matching still works on built-in enums
    match b {
        case Some(v) => print("match Some:", v)
        case Nothing => print("b is nothing")
    }

    # --- Maybe[str] ---
    s = Maybe[str].Some("hello")
    print("s.is_some  =", s.is_some())
    print("s.unwrap() =", s.unwrap())

    # --- Maybe[float] ---
    f = Maybe[float].Some(2.5)
    print("f.unwrap() =", f.unwrap())

    # --- Result[int, str] ---
    ok = Result[int, str].Ok(7)
    err = Result[int, str].Err("boom")
    print("ok.is_ok  =", ok.is_ok())
    print("ok.is_err =", ok.is_err())
    print("ok.unwrap =", ok.unwrap())
    print("err.is_ok  =", err.is_ok())
    print("err.is_err =", err.is_err())
    print("ok.expect('should be ok') =", ok.expect("should be ok"))

    # Recommended match usage: the error branch
    match err {
        case Ok(v) => print("unexpected:", v)
        case Err(msg) => print("error is:", msg)
    }
}