import asyncio

async def noop() {
}

async def bad() {
    xs = List[Task[None]]()
    xs.push(noop())
    ys = await asyncio.gather(xs)
    print(ys.len())
}

def main() {
    asyncio.run(bad())
}
