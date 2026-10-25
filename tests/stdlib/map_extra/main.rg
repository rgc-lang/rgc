def main() {
    m = Map[str, int]()
    print(m.len())
    m.put("a", 1)
    m.put("b", 2)
    m.put("a", 3)
    print(m.len(), m.get("a"), m.get("b"), m.get("z"))
    print(m.contains("a"), m.contains("z"))
    print(m.remove("a"), m.remove("a"), m.len())
    m.put("c", 4)
    print(m.len(), m.get("c"))
    ks = m.keys()
    vs = m.values()
    total = 0
    for v in vs {
        total = total + v
    }
    print(ks.len(), vs.len(), total)
    print(ks.contains("b"), ks.contains("c"), ks.contains("a"))
    for i in range(1000) {
        m.put("k" + to_string(i), i)
    }
    print(m.len(), m.get("k999"), m.get("k0"))
    mi = Map[int, str]()
    mi.put(5, "five")
    mi.put(7, "seven")
    print(mi.get(5), mi.get(7), mi.len())
    print(mi.remove(5), mi.len())
    mf = Map[float, int]()
    mf.put(1, 10)
    print(mf.get(1), mf.contains(2))
    mb = Map[bool, str]()
    mb.put(True, "yes")
    mb.put(False, "no")
    print(mb.get(True), mb.get(False), mb.len())
}
