# FFI: extern def declares C-ABI functions; symbols are resolved by the linker in libc.
# Type mapping: params int=C long long(i64), float=double, bool=_Bool(i8), str=ptr;
#          returns int=C int(i32, auto-sexted back to 64 bits at call sites), bool=_Bool(i8).
extern def puts(s: str) -> int
extern def abs(x: int) -> int
extern def atof(s: str) -> float
extern def isdigit(c: int) -> bool

def main() {
    puts("hello from libc puts (via extern def)")
    print("abs(-42) =", abs(-42))
    print("atof(\"2.5\") * 4 =", atof("2.5") * 4.0)
    print("isdigit('7') =", isdigit(55))    # '7' == 55
    print("isdigit('x') =", isdigit(120))
}
