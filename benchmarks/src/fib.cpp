// C++ counterpart of benchmarks/src/fib.rg
#include <cstdio>

long long fib(long long n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    std::printf("fib(38) = %lld\n", fib(38));
    return 0;
}