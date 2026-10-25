# Negative test: generic class bound — int does not implement interface Show
interface Show {
    def show(self) -> str
}

class Point : Show {
    x: int
    def show(self) -> str {
        return "Point"
    }
}

class Box[T: Show] {
    value: T
}

def main() {
    b = Box[int]()
}