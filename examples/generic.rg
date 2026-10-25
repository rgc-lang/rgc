# Generic functions (monomorphization) + interfaces (static implementation checks)

def identity[T](x: T) -> T {
    return x
}

def pair_sum[T](a: T, b: T) -> T {
    return a + b
}

interface Show {
    def show(self) -> str
}

class Point : Show {
    x: int
    def show(self) -> str {
        return "Point"
    }
}

def main() {
    print("identity(42) =", identity(42))
    print("identity(3.14) =", identity(3.14))
    print("pair_sum(2, 3) =", pair_sum(2, 3))
    print("pair_sum(1.5, 2.5) =", pair_sum(1.5, 2.5))

    p = Point()
    print("p.show() =", p.show())
}