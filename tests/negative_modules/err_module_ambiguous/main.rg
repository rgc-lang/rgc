# Two modules export a same-named function; bare-name call without an import: ambiguity error
import m1
import m2

def main() {
    print(label(1))
}
