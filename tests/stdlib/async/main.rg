import time
import asyncio

class Point {
    x: int
    y: int
}

async def add_async(a: int, b: int) -> int {
    time.sleep(0.02)
    return a + b
}

async def greet(name: str) -> str {
    return "hi " + name
}

async def half_of(v: int) -> float {
    return v / 2.0
}

async def negate(v: bool) -> bool {
    return not v
}

async def make_point(a: int) -> Point {
    p = Point()
    p.x = a
    p.y = a + 1
    return p
}

async def parse(v: int) -> Result[int, str] {
    if v < 0 {
        return Result[int, str].Err("negative")
    }
    return Result[int, str].Ok(v * 2)
}

async def outer(v: int) -> int {
    t = add_async(v, 10)
    r = await t
    return r * 2
}

async def slow_a() -> int {
    time.sleep(0.25)
    return 1
}

async def slow_b() -> int {
    time.sleep(0.25)
    return 2
}

async def cancellable(start: int) -> int {
    i = 0
    while i < 100 {
        if asyncio.cancelled() {
            return -1
        }
        time.sleep(0.01)
        i = i + 1
    }
    return start
}

async def driver() {
    t1 = add_async(20, 22)
    t2 = greet("rgc")
    t3 = half_of(5)
    t4 = negate(True)
    t5 = make_point(3)
    t6 = parse(21)
    t7 = parse(-1)
    t8 = outer(5)
    t9: Task[int] = add_async(7, 8)

    print("int", await t1)
    print("str", await t2)
    print("float", await t3)
    print("bool", await t4)
    p = await t5
    print("custom", p.x, p.y)
    r6 = await t6
    match r6 {
        case Ok(n) => print("ok", n)
        case Err(e) => print("err", e)
    }
    r7 = await t7
    match r7 {
        case Ok(n) => print("unexpected ok", n)
        case Err(e) => print("err", e)
    }
    print("nested", await t8)
    print("annotated", await t9)

    print("run", asyncio.run(add_async(40, 2)))

    start = time.now_monotonic()
    ta = slow_a()
    tb = slow_b()
    va = await ta
    vb = await tb
    elapsed = time.now_monotonic() - start
    print("parallel", elapsed < 0.45)
    print("slow", va + vb)

    tasks = List[Task[int]]()
    i = 0
    while i < 3 {
        tasks.push(add_async(i, i))
        i = i + 1
    }
    total = 0
    j = 0
    while j < tasks.len() {
        total = total + await tasks.get(j)
        j = j + 1
    }
    print("list", total)

    # Task.done(): False before completion, True after (observed before awaiting).
    dt = slow_a()
    print("done-before", dt.done())
    time.sleep(0.3)
    print("done-after", dt.done())
    print("done-value", await dt)

    # Task.wait(ms): returns False on timeout; the task is not consumed and can still be awaited.
    wt = slow_a()
    print("wait-timeout", wt.wait(100))
    print("wait-zero", wt.wait(0))
    print("wait-done", wt.wait(1000))
    print("wait-value", await wt)

    # Cooperative cancellation: the task polls asyncio.cancelled() and returns early; cancel does not consume the task.
    ct = cancellable(7)
    print("cancel-before", ct.cancelled())
    print("cancel-first", ct.cancel())
    print("cancel-second", ct.cancel())
    print("cancel-after", ct.cancelled())
    print("cancel-wait", ct.wait(1000))
    print("cancel-value", await ct)

    # Cancelling a completed task is a no-op: returns False, the result is unchanged.
    done_t = add_async(1, 1)
    time.sleep(0.05)
    print("cancel-done-first", done_t.done())
    print("cancel-done-request", done_t.cancel())
    print("cancel-done-flag", done_t.cancelled())
    print("cancel-done-value", await done_t)

    # A task that ignores cancellation still runs to completion: wait keeps reporting its completion state.
    stubborn = slow_a()
    print("cancel-ignore", stubborn.cancel())
    print("cancel-ignore-short", stubborn.wait(50))
    print("cancel-ignore-flag", stubborn.cancelled())
    print("cancel-ignore-value", await stubborn)

    # gather: waits for the whole task group in parallel, returning Task[List[T]].
    gt1 = slow_a()
    gt2 = slow_b()
    gt = List[Task[int]]()
    gt.push(gt1)
    gt.push(gt2)
    start2 = time.now_monotonic()
    gathered = asyncio.gather(gt)
    print("gather-done-before", gathered.done())
    vals = await gathered
    elapsed2 = time.now_monotonic() - start2
    print("gather-parallel", elapsed2 < 0.45)
    print("gather-len", vals.len())
    gsum = 0
    gi = 0
    while gi < vals.len() {
        gsum = gsum + vals.get(gi)
        gi = gi + 1
    }
    print("gather-sum", gsum)

    # gather supports custom payload types.
    pts = List[Task[Point]]()
    pts.push(make_point(5))
    pts.push(make_point(7))
    pvals = await asyncio.gather(pts)
    p0 = pvals.get(0)
    p1 = pvals.get(1)
    print("gather-custom", p0.x, p1.y)

    # An empty-list gather returns an empty list.
    empty = List[Task[int]]()
    evals = await asyncio.gather(empty)
    print("gather-empty", evals.len())

    # gather supports str payloads.
    sts = List[Task[str]]()
    sts.push(greet("x"))
    sts.push(greet("y"))
    svals = await asyncio.gather(sts)
    print("gather-str", svals.len(), svals.get(0), svals.get(1))

    # asyncio.run can directly bridge a Task produced by gather.
    rt = List[Task[int]]()
    rt.push(add_async(1, 2))
    rt.push(add_async(3, 4))
    rvals = asyncio.run(asyncio.gather(rt))
    print("gather-run", rvals.len(), rvals.get(0), rvals.get(1))

    # wait_any: returns the index of the first completed task without consuming; the rest can be cancelled/awaited.
    wa_slow = slow_a()
    wa_fast = add_async(30, 12)
    wa = List[Task[int]]()
    wa.push(wa_slow)
    wa.push(wa_fast)
    wa_idx = asyncio.wait_any(wa)
    print("wait-any-idx", wa_idx)
    print("wait-any-value", await wa.get(wa_idx))
    wa_slow.cancel()
    print("wait-any-cancel", wa_slow.cancelled())
    print("wait-any-slow", await wa_slow)

    # An empty list has no awaitable tasks; returns -1.
    wa_empty = List[Task[int]]()
    print("wait-any-empty", asyncio.wait_any(wa_empty))
}

def main() {
    asyncio.run(driver())
    print("cancel-outside", asyncio.cancelled())
    mt = add_async(1, 2)
    mts = List[Task[int]]()
    mts.push(mt)
    print("wait-any-main", asyncio.wait_any(mts))
    print("wait-any-main-value", asyncio.run(mt))
}
