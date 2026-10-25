# Generic classes: monomorphization generates concrete structs

class Box[T] {
    value: T
    def get(self) -> T {
        return self.value
    }
}

def main() {
    b = Box[int]()
    b.value = 42
    print("b.get() =", b.get())

    f = Box[float]()
    f.value = 3.14
    print("f.get() =", f.get())
}