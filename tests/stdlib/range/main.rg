def main() {
    s = ""
    for i in range(4) {
        s = s + to_string(i)
    }
    print("one", s)

    s = ""
    for i in range(2, 5) {
        s = s + to_string(i)
    }
    print("two", s)

    s = ""
    for i in range(5, 0, -1) {
        s = s + to_string(i)
    }
    print("down", s)

    s = ""
    for i in range(1, 10, 3) {
        s = s + to_string(i)
    }
    print("step", s)

    count = 0
    step = 0
    for i in range(0, 5, step) {
        count = count + 1
    }
    print("zero", count)

    count = 0
    for i in range(0, 5, 2 - 2) {
        count = count + 1
    }
    print("zeroexpr", count)

    count = 0
    for i in range(5, 5) {
        count = count + 1
    }
    print("empty", count)

    s = ""
    end = 4
    for i in range(1, end) {
        s = s + to_string(i)
    }
    print("dyn", s)
}
