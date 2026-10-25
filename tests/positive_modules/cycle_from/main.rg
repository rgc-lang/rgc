# from-import cycle: resolution happens after the fully merged AST, so both directions work
import os
from a import call_gb
from b import call_ga

def main() {
    if call_gb() != 12 {
        os.exit(1)
    }
    if call_ga() != 21 {
        os.exit(1)
    }
}
