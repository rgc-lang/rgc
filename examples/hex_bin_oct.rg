# Hexadecimal / binary / octal integer literals

def main() {
    a = 0xFF
    b = 0b1010
    c = 0o17
    print("hex 0xFF =", a)      # 255
    print("bin 0b1010 =", b)    # 10
    print("oct 0o17 =", c)      # 15

    # Bitwise operations combined with radix literals
    mask = 0xF0
    print("mask & a =", mask & a)   # 240 & 255 = 240
    print("shifted =", 0b1 << 4)    # 16
}