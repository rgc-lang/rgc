# Negative test: int does not implement interface Show; instantiating describe[int] should error
interface Show {
    def show(self) -> str
}

class Point : Show {
    x: int
    def show(self) -> str {
        return "Point"
    }
}

def describe[T: Show](x: T) -> str {
    return x.show()
}

def main() {
    print(describe(42))
}