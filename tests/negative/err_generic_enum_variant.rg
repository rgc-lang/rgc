# Negative test: unknown variant of a generic enum
enum Maybe[T] {
    Some(T)
    Nothing
}

def main() {
    a = Maybe[int].Nope()
}