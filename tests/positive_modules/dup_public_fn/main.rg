# Same-named public functions are physically isolated via module$name; qualified calls resolve independently;
# a uniquely exported symbol can be called by bare name; same-named private helpers across modules do not conflict.
import m1
import m2
import other

def main() {
    print(m1.label(1))
    print(m2.label(2))
    print(unique_greet())
}
