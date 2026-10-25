# Module shape_b: class Point with the same name as shape_a (physically isolated, no conflict)
public class Point {
    tag: str

    def show(self) -> str {
        return "B:" + self.tag
    }
}

public def make(tag: str) -> Point {
    p = Point()
    p.tag = tag
    return p
}
