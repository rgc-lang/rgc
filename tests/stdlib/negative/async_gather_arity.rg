import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    xs = List[Task[int]]()
    ys = List[Task[int]]()
    r = await asyncio.gather(xs, ys)
    print(r.len())
}

def main() {
    asyncio.run(bad())
}
