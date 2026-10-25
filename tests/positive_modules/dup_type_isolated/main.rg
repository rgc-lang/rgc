# Same-named types: each module's Point registers separately as module$Point; construction/methods/annotations do not interfere
import shape_a
import shape_b

def main() {
    a = shape_a.make(1, 2)
    b = shape_b.make("tag")
    print(a.show())
    print(b.show())
}
