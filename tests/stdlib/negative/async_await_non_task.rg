import asyncio

async def bad() -> int {
    return await 1
}

def main() {
    asyncio.run(bad())
}
