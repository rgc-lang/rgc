# Standard library: Map[K, V] builtin container (a linear-search symbol table)

def main() {
    # Map[str, int]
    sym = Map[str, int]()
    sym.put("a", 1)
    sym.put("b", 2)
    sym.put("c", 3)
    print("len =", sym.len())
    print("contains 'a' =", sym.contains("a"))
    print("contains 'z' =", sym.contains("z"))
    print("get 'b' =", sym.get("b"))
    print("get 'missing' =", sym.get("missing"))

    # Updating an existing key
    sym.put("a", 100)
    print("after update get 'a' =", sym.get("a"))
    print("len still =", sym.len())

    # Map[int, str]
    names = Map[int, str]()
    names.put(1, "one")
    names.put(2, "two")
    print("names.get(1) =", names.get(1))
    print("names.get(3) =", names.get(3))
    print("names contains 2 =", names.contains(2))

    # Map[str, float]
    scores = Map[str, float]()
    scores.put("alice", 9.5)
    scores.put("bob", 8.25)
    print("scores.get('alice') =", scores.get("alice"))
}