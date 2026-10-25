# RGC benchmark: recursive fib(38) — integer arithmetic + function calls.
def fib(n: int) -> int {
    if n <= 1 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

def main() {
    print("fib(38) =", fib(38))
}