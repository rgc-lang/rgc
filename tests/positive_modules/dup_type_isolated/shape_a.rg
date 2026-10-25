# Module shape_a: defines a same-named class Point
public class Point {
    x: int
    y: int

    def show(self) -> str {
        return "A(" + to_string(self.x) + "," + to_string(self.y) + ")"
    }
}

public def make(x: int, y: int) -> Point {
    p = Point()
    p.x = x
    p.y = y
    return p
}
