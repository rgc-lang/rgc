import asyncio

async def bad() {
    xs = List[int]()
    xs.push(1)
    print(asyncio.wait_any(xs))
}

def main() {
    asyncio.run(bad())
}
