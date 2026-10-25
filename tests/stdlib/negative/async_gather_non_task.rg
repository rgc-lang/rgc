import asyncio

async def bad() {
    xs = List[int]()
    xs.push(1)
    ys = await asyncio.gather(xs)
    print(ys.len())
}

def main() {
    asyncio.run(bad())
}
