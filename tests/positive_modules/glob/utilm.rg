# glob import source: public function / public generic / public class / private symbol
public def double(v: int) -> int {
    return v * 2
}

public def pick[T](v: T) -> T {
    return v
}

public class Box {
    v: int
}

def secret(v: int) -> int {
    return v + 100
}
