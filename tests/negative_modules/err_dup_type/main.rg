# Two modules define a same-named class; bare-name reference without an import: ambiguity error
import ta
import tb

def main() {
    c = Conf()
    print(c)
}
