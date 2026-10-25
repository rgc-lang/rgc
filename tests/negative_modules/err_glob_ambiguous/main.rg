# Negative test: glob-importing two modules' same-named public function -> bare-name ambiguity
from am import *
from bm import *

def main() {
    print(val())
}
