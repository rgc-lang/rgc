import asyncio

async def work() -> int {
    return 1
}

async def bad() {
    t = work()
    v = await t
    if t.done() {
        print(v)
    }
}

def main() {
    asyncio.run(bad())
}
