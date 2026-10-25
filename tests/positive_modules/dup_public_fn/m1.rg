# Module m1: exports the same-named public function label as m2; physically isolated, no conflict
public def label(i: int) -> str {
    return "m1:" + to_string(i)
}
