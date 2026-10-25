# Ownership + move semantics example
# Custom types (class/enum) use move semantics by default; scalars copy by default.
# A moved variable cannot be read again until it is reassigned (compile-time detection, zero runtime overhead).

class Point {
    x: int
    def sum(self) -> int {
        return self.x
    }
}

enum Maybe {
    Some(int)
    Nothing
}

def take(p: Point) -> int {
    return p.x
}

def unwrap(m: Maybe) -> int {
    match m {
        case Some(v) => v
        case Nothing => 0
    }
}

def main() {
    # 1) move assignment: a's ownership transfers to b
    a = Point()
    a.x = 5
    b = a
    print("b.x =", b.x)          # 5

    # 2) move on call: c's ownership transfers to the function parameter
    c = Point()
    c.x = 6
    print("take(c) =", take(c))

    # 3) reassignment restores usability: after d is moved, rebinding makes it usable again
    d = Point()
    d.x = 7
    e = d                        # move d -> e
    d = Point()                    # reassignment makes d usable again
    d.x = 8
    print("e.x =", e.x, "d.x =", d.x)

    # 4) enum move
    m = Some(42)
    n = m                        # move m -> n
    print("unwrap(n) =", unwrap(n))

    # 5) method-call self is a read-only borrow; it does not move
    p = Point()
    p.x = 9
    print("p.sum() =", p.sum(), "p.x =", p.x)
}