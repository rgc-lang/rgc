async def work() -> int {
    return 1
}

def main() {
    t = work()
    print(await t)
}
