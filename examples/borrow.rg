# Borrow checker example (@ shared borrow / @var mutable borrow)
# Borrows are a compile-time concept; at the LLVM layer they are just pointer passing, with zero runtime overhead.

class Counter {
    value: int
    def inc(self) {
        self.value = self.value + 1
    }
}

def read(c: @Counter) -> int {
    return c.value
}

def increment(c: @var Counter) {
    c.value = c.value + 1
}

def main() {
    # 1) shared borrow: multiple @ can coexist, read-only
    x = Counter()
    x.value = 10
    r1 = @x
    r2 = @x
    print("read(r1) =", read(r1))
    print("read(r2) =", read(r2))

    # 2) mutable borrow: @var has exclusive access, writable
    y = Counter()
    y.value = 20
    increment(@var y)
    print("y.value =", y.value)

    # 3) call-site borrow: after passing @x, x is still usable (the borrow is only active during the call)
    print("read(@x) =", read(@x))
    print("x.value =", x.value)

    # 4) method-call self is a hidden shared borrow and does not conflict with other borrows
    z = Counter()
    z.value = 30
    print("before z.inc =", z.value)
    z.inc()
    print("after z.inc =", z.value)
}