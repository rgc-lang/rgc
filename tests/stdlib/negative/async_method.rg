class Worker {
    async def run(self) -> int {
        return 1
    }
}

def main() {
    w = Worker()
    print(w.run())
}
