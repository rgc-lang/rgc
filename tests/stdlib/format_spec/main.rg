def main() {
    print(format("{} {{ }} {}", 42, 7))
    print(format("{:d} {:x} {:X} {:o} {:b} {:08x} {:#x} {:#o} {:#b}", 255, 255, 255, 8, 5, 255, 255, 8, 5))
    print(format("{:+d} {:+d}", 5, -5))
    print(format("{:8d}|{:<8d}|{:>8d}|{:^8d}|{:08d}", 42, 42, 42, 42, 42))
    print(format("{:f} {:.2f} {:10.3f} {:^10.2f}", 3.14159, 3.14159, 3.14159, 3.14159))
    print(format("{:8s}|{:<8s}|{:>8s}|{:^8s}|{:.3s}", "abc", "abc", "abc", "abc", "abcdef"))
    print(format("{:8s}|{:^8s}", True, False))
}
