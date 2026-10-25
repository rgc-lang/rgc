# Negative test: generic enum variant argument type mismatch
enum Maybe[T] {
    Some(T)
    Nothing
}

def main() {
    a = Maybe[int].Some(1.5)
}