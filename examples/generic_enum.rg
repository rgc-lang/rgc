# Generic enums: monomorphization generates a concrete enum type

enum Maybe[T] {
    Some(T)
    Nothing
}

def unwrap_or_default(m: Maybe[int], fallback: int) -> int {
    match m {
        case Some(v) => v
        case Nothing => fallback
        case _ => fallback
    }
}

def main() {
    a = Maybe[int].Some(42)
    b = Maybe[int].Nothing()

    print("unwrap(Some(42)) =", unwrap_or_default(a, 0))
    print("unwrap(Nothing)  =", unwrap_or_default(b, 7))

    # Generic enum in type-annotation form
    n: Maybe[float] = Maybe[float].Nothing()
    print("float nothing ok")
}