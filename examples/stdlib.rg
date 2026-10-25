# Standard library batch 1: to_string / str methods / List

def main() {
    # --- to_string ---
    s = to_string(42)
    print("to_string(42) =", s)
    print("to_string(3.14) =", to_string(3.14))
    print("to_string(True) =", to_string(True))

    # --- str concatenation and methods ---
    msg = "Hello, " + "RGC"
    print("concat =", msg)
    print("len =", msg.len())
    print("contains 'lo,' =", msg.contains("lo,"))
    print("startswith 'Hello' =", msg.startswith("Hello"))
    print("endswith 'RGC' =", msg.endswith("RGC"))
    print("endswith 'XYZ' =", msg.endswith("XYZ"))

    # --- List[int] ---
    xs = List[int]()
    xs.push(1)
    xs.push(2)
    xs.push(3)
    print("xs.len =", xs.len())
    print("xs.get(0) =", xs.get(0))
    xs.set(1, 20)
    print("xs.get(1) =", xs.get(1))
    print("contains 3 =", xs.contains(3))
    print("contains 99 =", xs.contains(99))
    print("pop =", xs.pop())
    print("after pop len =", xs.len())

    total = 0
    for x in xs {
        total = total + x
    }
    print("sum =", total)

    # --- List[str] ---
    names = List[str]()
    names.push("alice")
    names.push("bob")
    names.push("carol")
    for n in names {
        print("name:", n)
    }
    print("names contains 'bob' =", names.contains("bob"))
    print("joined =", names.get(0) + " & " + names.get(1))

    # --- List[float] ---
    fs = List[float]()
    fs.push(1)
    fs.push(2.5)
    total_f = 0.0
    for f in fs {
        total_f = total_f + f
    }
    print("float sum =", total_f)
    print("fs.contains(2.5) =", fs.contains(2.5))
}