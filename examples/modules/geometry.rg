# Module geometry.rg: used via import geometry

public class Point {
    x: int
    y: int
    def sum(self) -> int {
        return self.x + self.y
    }
}

# Private function: only visible inside the module
def double(v: int) -> int {
    return v * 2
}

public def make_point(x: int, y: int) -> Point {
    p = Point()
    p.x = x
    p.y = y
    return p
}

public def norm_sq(p: Point) -> int {
    return double(p.x * p.x + p.y * p.y)
}