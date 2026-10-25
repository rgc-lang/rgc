# Generic class with a bound + generic enum + bare variant construction with a single instantiation

interface Show {
    def show(self) -> str
}

class Point : Show {
    x: int
    def show(self) -> str {
        return "Point"
    }
}

# Generic class with a bound: T must implement Show
class Box[T: Show] {
    value: T
    def describe(self) -> str {
        return self.value.show()
    }
}

# Generic enum (payload is a basic type)
enum Maybe[T] {
    Some(T)
    Nothing
}

def main() {
    p = Point()
    p.x = 5

    b = Box[Point]()
    b.value = p
    print("Box[Point].describe() =", b.describe())

    m = Maybe[int].Some(10)
    match m {
        case Some(v) => print("nested Some ->", v)
        case Nothing => print("nested Nothing")
        case _ => print("?")
    }

    # Bare variant construction works with a single instantiation (no ambiguity)
    n = Maybe[int].Nothing()
    s = Some(99)
    match s {
        case Some(v) => print("bare Some ->", v)
        case Nothing => print("bare Nothing")
        case _ => print("?")
    }
}