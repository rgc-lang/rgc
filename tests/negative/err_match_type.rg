enum Shape {
    Circle(float)
    Rect { w: float, h: float }
}
def bad(s: Shape) -> int {
    match s {
        case Circle(r) => r
        case _ => 0
    }
}
