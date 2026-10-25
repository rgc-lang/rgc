# RGC benchmark: integer loop, sum(0 .. N-1) with N = 1e9.
# LLVM -O2 recognizes the arithmetic series and folds it into a closed form.
def main() {
    total = 0
    for i in range(1000000000) {
        total = total + i
    }
    print("sum =", total)
}