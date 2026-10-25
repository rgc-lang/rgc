# glob import: public symbols work by bare name; local definitions take priority; qualified calls are unaffected
import os
import utilm
from utilm import *

def double(v: int) -> int {
    return v * 3
}

def main() {
    if double(10) != 30 {
        os.exit(1)
    }
    if utilm.double(10) != 20 {
        os.exit(1)
    }
    if pick(7) != 7 {
        os.exit(1)
    }
    b = Box()
    b.v = 5
    if b.v != 5 {
        os.exit(1)
    }
}
