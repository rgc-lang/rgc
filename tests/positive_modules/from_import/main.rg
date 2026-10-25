# from-import: load a module and import its symbols
# The compiler supports the from x import y syntax.

from mymath import double

def main() {
    print("double(21) =", double(21))
}