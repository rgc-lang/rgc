# Generics in a module: private generic (called within the module), public generic with qualified call
import m

def main() {
    print(m.wrap(5))
    print(m.pick(7))
}
