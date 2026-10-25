def check(s: str) {
    r = s.to_float()
    match r {
        case Ok(v) => print(s, "->", to_string(v))
        case Err(e) => print(s, "-> Err")
    }
}

def main() -> int {
    check("3.5")
    check("-0.25")
    check("1e3")
    check("42")
    check("3.5x")
    check("")
    check("abc")
    return 0
}
