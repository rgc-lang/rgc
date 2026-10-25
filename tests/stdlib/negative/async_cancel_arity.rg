import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    t = work()
    print(t.cancel(1))
    print(await t)
}

def main() {
    asyncio.run(bad())
}
