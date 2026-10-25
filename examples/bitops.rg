# Bitwise operators: & | ^ << >> (requires int operands)

def main() {
    a = 12   # 0b1100
    b = 10   # 0b1010
    print("a & b   =", a & b)      # 8
    print("a | b   =", a | b)      # 14
    print("a ^ b   =", a ^ b)      # 6
    print("a << 1 =", a << 1)      # 24
    print("b >> 1 =", b >> 1)      # 5
    print("mixed  =", (1 | 2) << 2) # 12
    print("mask   =", (a >> 2) & 3) # 12>>2=3, 3&3=3
}