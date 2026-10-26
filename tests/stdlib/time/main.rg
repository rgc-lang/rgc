import time

def main() {
    start = time.now_monotonic()
    time.sleep(0.02)
    end = time.now_monotonic()
    print("monotonic", end > start)
    print("elapsed_reasonable", end - start < 5.0)
    print("now_positive", time.now() > 1700000000)
    ms0 = time.monotonic_ms()
    time.sleep(0.02)
    ms1 = time.monotonic_ms()
    print("monotonic_ms_positive", ms0 > 0)
    print("monotonic_ms_elapsed", ms1 >= ms0 + 10)
    time.sleep(0)
}
