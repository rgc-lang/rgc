enum Shape {
    Circle(float)
}
def bad(s: Shape) -> float {
    match s {
        case Triangle(x) => x
        case _ => 0.0
    }
}
