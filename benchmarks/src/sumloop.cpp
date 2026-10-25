// C++ counterpart of benchmarks/src/sumloop.rg
#include <cstdio>

int main() {
    long long total = 0;
    for (long long i = 0; i < 1000000000LL; ++i) {
        total += i;
    }
    std::printf("sum = %lld\n", total);
    return 0;
}