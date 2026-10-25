// C++ counterpart of benchmarks/src/floatloop.rg
#include <cstdio>

int main() {
    double s = 0.0;
    for (long long i = 0; i < 500000000LL; ++i) {
        s += 1.0 / (double)(i + 1);
    }
    std::printf("sum = %.10f\n", s);
    return 0;
}