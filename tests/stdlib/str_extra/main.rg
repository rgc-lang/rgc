def main() {
    print("hello".find("l"), "hello".rfind("l"), "hello".find("z"))
    print("[" + "  hi there \n".trim() + "]")
    print("[" + "  hi ".trim_start() + "]", "[" + " hi  ".trim_end() + "]")
    print("a,b,a".replace("a", "X"))
    print("ab".repeat(3), "ab".repeat(0).len())
    ls = "a\r\nb\n".lines()
    print(ls.len(), ls.get(0), ls.get(1))
    print("".lines().len())
    print("abc".find(""), "abc".rfind(""))
}
