import random

def main() {
    random.seed(123)
    a = random.random_int(1, 6)
    b = random.random_int(-5, 5)
    print("range", a >= 1 and a <= 6, b >= -5 and b <= 5)
    random.seed(123)
    print("repeatable", random.random_int(1, 6) == a)
    print("single_value", random.random_int(7, 7) == 7)
    f = random.random_float()
    print("float_range", f >= 0.0 and f < 1.0)
    random.seed(123)
    g = random.random_float()
    random.seed(123)
    print("float_repeatable", random.random_float() == g)
}
