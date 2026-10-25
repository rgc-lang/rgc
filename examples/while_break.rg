# while loops / break / continue / pass example

def main() {
    # while + continue + break
    i = 0
    while i < 6 {
        i = i + 1
        if i == 2 {
            continue
        }
        if i == 5 {
            break
        }
        print("i =", i)
    }
    print("after loop, i =", i)

    # pass: an empty statement
    n = 0
    while n < 3 {
        n = n + 1
        pass
    }
    print("n =", n)

    # using break in a for loop
    total = 0
    for k in range(10) {
        if k == 4 {
            break
        }
        total = total + k
    }
    print("total 0..3 =", total)
}