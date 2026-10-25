# Module isolation positive test: the two modules' private helpers do not conflict
import m1
import m2

def main() {
    print("m1:", from_m1(1))
    print("m2:", from_m2(1))
}