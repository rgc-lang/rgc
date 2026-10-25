# RGC example: Python-like syntax, compiled via LLVM

def add(a: int, b: int) -> int {
    return a + b
}

def classify(score: int) -> str {
    if score >= 90 {
        return "excellent"
    } elif score >= 60 {
        return "pass"
    } else {
        return "fail"
    }
}

def main() {
    x = 40
    y: int = 2
    total = add(x, y)
    print("hello from RGC, x + y =", total)

    if x > 10 and y < 10 {
        print("condition: ok")
    } else {
        print("condition: no")
    }

    print("score 95 =>", classify(95))
    print("score 70 =>", classify(70))
    print("score 30 =>", classify(30))

    # Logical operators, integer division, and exponentiation
    flag = not (x == 0)
    print("flag =", flag)
    print("7 // 2 =", 7 // 2, " 7 % 2 =", 7 % 2, " 2 ** 10 =", 2 ** 10)
}
