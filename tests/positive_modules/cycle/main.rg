# Cyclic imports: calls in both directions resolve
import os
import a
import b

def main() {
    if fa() != 3 {
        os.exit(1)
    }
    if b.fb() != 2 {
        os.exit(1)
    }
}
