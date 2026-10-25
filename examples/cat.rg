# Phase 8 milestone: a usable command-line tool written in RGC (a cat clone)
#
# Usage:  rgc examples/cat.rg -o /tmp/cat
#         /tmp/cat file1.rg file2.rg

import io

def main() {
    first = True
    for path in args() {
        if not first {
            match read_file(path) {
                case Ok(content) => print(content)
                case Err(msg)    => print("cat:", msg)
            }
        }
        first = False
    }
}