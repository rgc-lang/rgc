# Standard library: str extension methods char_at / slice / to_int / split / join

def main() {
    s = "hello world"
    print("char_at(0) =", s.char_at(0))       # 104 = 'h'
    print("char_at(6) =", s.char_at(6))       # 119 = 'w'
    print("slice(0,5) =", s.slice(0, 5))      # hello
    print("slice(6,11) =", s.slice(6, 11))    # world

    # to_int: success and failure
    r = "12345".to_int()
    print("to_int is_ok =", r.is_ok())
    match r {
        case Ok(v) => print("value =", v)
        case Err(msg) => print("err:", msg)
    }
    r2 = "abc".to_int()
    print("bad to_int is_err =", r2.is_err())
    match r2 {
        case Ok(v) => print("unexpected:", v)
        case Err(msg) => print("to_int error:", msg)
    }

    # split / join
    parts = "a,b,c".split(",")
    print("parts len =", parts.len())
    for p in parts {
        print("part:", p)
    }
    joined = "-".join(parts)
    print("joined =", joined)

    csv = "x,y,z".split(",")
    print("csv[1] =", csv.get(1))
    print("empty tail: len =", "a,b,".split(",").len())
}