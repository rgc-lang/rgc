# Cyclic imports: a -> b -> a (the loader skips modules being loaded; Sema resolves globally)
import b

public def fa() -> int {
    return fb() + 1
}
