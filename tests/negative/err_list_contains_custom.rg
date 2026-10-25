# List.contains() does not yet support custom element types (no generic equality)
class Point {
    x: int
}

def main() {
    xs = List[Point]()
    p = Point()
    p.x = 1
    xs.push(p)
    print(xs.contains(p))
}