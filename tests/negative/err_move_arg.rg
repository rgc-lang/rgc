class Point {
    x: int
}
def take(p: Point) -> int {
    return p.x
}
def main() {
    a = Point()
    take(a)
    print(a.x)
}
