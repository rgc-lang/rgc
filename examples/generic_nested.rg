# Nested generic types: class/enum fields reference concrete instantiated types

class Box[T] {
    value: T
    def get(self) -> T {
        return self.value
    }
}

enum Maybe[T] {
    Some(T)
    Nothing
}

class Holder {
    b: Box[int]
    m: Maybe[int]
}

def main() {
    h = Holder()
    h.b = Box[int]()
    h.b.value = 123
    print("nested generic field ->", h.b.get())

    h.m = Maybe[int].Some(55)
    match h.m {
        case Some(v) => print("nested enum field  ->", v)
        case Nothing => print("nested Nothing")
        case _ => print("?")
    }
}