import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    xs = List[Task[int]]()
    print(asyncio.wait_any(xs, 10))
}

def main() {
    asyncio.run(bad())
}
