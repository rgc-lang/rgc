# Module m1: private helper with the same name as m2's, but no conflict
public def from_m1(v: int) -> int {
    return helper(v)
}

def helper(v: int) -> int {
    return v + 100
}