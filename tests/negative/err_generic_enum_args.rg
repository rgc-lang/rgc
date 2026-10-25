# Negative test: generic enum type argument count mismatch
enum Maybe[T] {
    Some(T)
    Nothing
}

def main() {
    a = Maybe[int, float].Some(1)
}