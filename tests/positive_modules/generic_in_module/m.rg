# Module m: private generic + public generic + qualified call to a public generic
public def wrap(v: int) -> int {
    return pick(v) + plain(v)
}

public def pick[T](v: T) -> T {
    return v
}

def plain(v: int) -> int {
    return v * 10
}
