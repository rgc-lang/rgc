import time

def main() {
    start = time.now_monotonic()
    time.sleep(0.02)
    end = time.now_monotonic()
    print("monotonic", end > start)
    print("elapsed_reasonable", end - start < 5.0)
    print("now_positive", time.now() > 1700000000)
    time.sleep(0)
}
