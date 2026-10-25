# RGC benchmark: harmonic series partial sum, 5e8 terms.
# Floating-point loop that cannot be folded — measures raw loop throughput.
def main() {
    s = 0.0
    for i in range(500000000) {
        s = s + 1.0 / (i + 1)
    }
    print("sum =", s)
}