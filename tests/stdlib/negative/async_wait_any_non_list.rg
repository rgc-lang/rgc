import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    t = work()
    print(asyncio.wait_any(t))
    await t
}

def main() {
    asyncio.run(bad())
}
