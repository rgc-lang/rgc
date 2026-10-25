# b refers back to a: mutual references are conflict-free under the physical namespace
import a

public def fb() -> int {
    return 2
}
