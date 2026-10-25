import asyncio

async def work() -> int {
    return 1
}

async def twice() -> int {
    t = work()
    a = await t
    b = await t
    return a + b
}

def main() {
    print(asyncio.run(twice()))
}
