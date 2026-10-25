# RGC benchmark: naive GEMM, 512x512 double, row-major flat storage.
# Measures dense compute (mul-add chain) + memory access pattern; the inner
# loop is a serial FP reduction, so neither side vectorizes without fast-math.
def main() {
    N = 512
    a = List[float]()
    b = List[float]()
    c = List[float]()
    i = 0
    while i < N * N {
        a.push((i % 7) * 0.125)
        b.push((i % 5) * 0.2)
        c.push(0.0)
        i = i + 1
    }
    i = 0
    while i < N {
        k = 0
        while k < N {
            aik = a.get(i * N + k)
            j = 0
            while j < N {
                c.set(i * N + j, c.get(i * N + j) + aik * b.get(k * N + j))
                j = j + 1
            }
            k = k + 1
        }
        i = i + 1
    }
    s = 0.0
    i = 0
    while i < N * N {
        s = s + c.get(i)
        i = i + 1
    }
    print("gemm checksum =", s)
}
