def main() -> int {
    print(format("x = {}, y = {}, ok = {}", 42, 2.5, True))
    name = "RGC"
    print(format("hi {}, len = {}", name, name.len()))
    print(format("no placeholders"))
    print(format("{} + {} = {}", 1, 2, 3))
    return 0
}
