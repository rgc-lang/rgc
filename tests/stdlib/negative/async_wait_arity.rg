import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    t = work()
    print(t.wait())
    print(await t)
}

def main() {
    asyncio.run(bad())
}
