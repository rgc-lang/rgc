// C++ counterpart of benchmarks/src/gemm.rg
#include <cstdio>
#include <vector>

int main() {
    const int N = 512;
    std::vector<double> a(N * N), b(N * N), c(N * N, 0.0);
    for (int i = 0; i < N * N; ++i) {
        a[i] = (i % 7) * 0.125;
        b[i] = (i % 5) * 0.2;
    }
    for (int i = 0; i < N; ++i) {
        for (int k = 0; k < N; ++k) {
            double aik = a[i * N + k];
            for (int j = 0; j < N; ++j) {
                c[i * N + j] += aik * b[k * N + j];
            }
        }
    }
    double s = 0.0;
    for (int i = 0; i < N * N; ++i) {
        s += c[i];
    }
    std::printf("gemm checksum = %.6f\n", s);
    return 0;
}
