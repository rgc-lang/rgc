# Module m2: private helper with the same name as m1's
public def from_m2(v: int) -> int {
    return helper(v)
}

def helper(v: int) -> int {
    return v + 200
}