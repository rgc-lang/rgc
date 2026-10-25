def main() -> int {
    xs = List[str]()
    xs.push("a")
    xs.push("b")
    print(xs.len(), xs.get(0))
    xs.clear()
    print(xs.len())
    print(xs.contains("a"))
    xs.push("c")
    print(xs.len(), xs.get(0))
    return 0
}
