# Hierarchical module: physical prefix net$tcp
public def ping() -> int {
    return 42
}

public def pick[T](v: T) -> T {
    return v
}

public class Conn {
    port: int
}

public def connect(c: Conn) -> int {
    return c.port + 1
}
