import helper

class Calc {
    x: int
    def add(self, y: int) -> int {
        return self.x + y
    }
}

def main() -> int {
    print("qualified =", helper.twice(21))
    math = Calc()
    math.x = 40
    print("method =", math.add(2))
    return 0
}
