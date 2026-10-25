# Generic bound constraint: T must implement the Show interface

interface Show {
    def show(self) -> str
}

class Point : Show {
    x: int
    y: int
    def show(self) -> str {
        return "Point"
    }
}

class Line : Show {
    a: int
    b: int
    def show(self) -> str {
        return "Line"
    }
}

# With T constrained by Show, interface methods can be called directly in the body
def describe[T: Show](x: T) -> str {
    return x.show()
}

def main() {
    p = Point()
    p.x = 1
    p.y = 2
    print("describe(Point) =", describe(p))

    l = Line()
    l.a = 3
    l.b = 4
    print("describe(Line)  =", describe(l))
}