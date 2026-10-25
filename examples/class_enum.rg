# Classes / enums / pattern matching / loops example

class Point {
    x: int
    y: int
    def sum(self) -> int {
        return self.x + self.y
    }
}

enum Shape {
    Circle(float)
    Rect { w: float, h: float }
}

def area(s: Shape) -> float {
    match s {
        case Circle(r) => 3.14159 * r * r
        case Rect { w, h } => w * h
        case _ => 0.0
    }
}

def main() {
    p = Point()
    p.x = 3
    p.y = 4
    print("p.sum() =", p.sum())

    c = Circle(2.0)
    r = Rect(3.0, 4.0)
    print("area(circle) =", area(c))
    print("area(rect)  =", area(r))

    total = 0
    for i in range(5) {
        total = total + i
    }
    print("sum 0..4 =", total)
}