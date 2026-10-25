# Standard library: args() command-line arguments (including the program name, like Python's sys.argv)

def main() {
    argv = args()
    print("argc =", argv.len())
    if argv.len() > 0 {
        print("argv[0] =", argv.get(0))
    }
    i = 0
    for a in argv {
        print("arg[", i, "] =", a)
        i = i + 1
    }
    print("contains 'rgc' =", argv.contains("rgc"))
}