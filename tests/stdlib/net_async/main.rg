import net
import net_async
import udp
import asyncio
import time

async def server_side(lfd: int, timeout: int) -> str {
    a = await net_async.accept(lfd, timeout)
    if not a.ok {
        return "accept_error:" + a.error
    }
    s = a.stream
    r = await net_async.recv(s.fd, 64, timeout)
    if not r.ok {
        s.close()
        return "recv_error:" + r.error
    }
    z = await net_async.send(s.fd, "pong:" + r.value, timeout)
    s.close()
    if not z.ok {
        return "send_error:" + z.error
    }
    return "server:" + r.value + ":" + to_string(z.sent)
}

async def client_side(port: int, timeout: int) -> str {
    c = await net_async.connect_to("127.0.0.1", port, timeout)
    if not c.ok {
        return "connect_error:" + c.error
    }
    s = c.stream
    z = await net_async.send(s.fd, "ping", timeout)
    if not z.ok {
        s.close()
        return "send_error:" + z.error
    }
    r = await net_async.recv(s.fd, 64, timeout)
    s.close()
    if not r.ok {
        return "recv_error:" + r.error
    }
    return "client:" + r.value + ":" + to_string(z.sent)
}

async def recv_timeout(fd: int) -> str {
    r = await net_async.recv(fd, 16, 100)
    if r.ok {
        return "unexpected:" + r.value
    }
    return r.error
}

async def wait_forever(fd: int) -> int {
    r = await net_async.recv(fd, 16, -1)
    if r.error == "cancelled" {
        return 7
    }
    return 0
}

async def cancel_orchestrator(fd: int) -> int {
    t = wait_forever(fd)
    time.sleep(0.12)
    t.cancel()
    return await t
}

async def udp_exchange(a: UdpSocket, b: UdpSocket) -> str {
    z = await net_async.udp_send(a.fd, a.family, "ping", "127.0.0.1", b.local_port(), 1000)
    if not z.ok {
        return "udp_send_error:" + z.error
    }
    r = await net_async.udp_recv(b.fd, 64, 1000)
    if not r.ok {
        return "udp_recv_error:" + r.error
    }
    if r.data != "ping" or r.port != a.local_port() {
        return "udp_mismatch"
    }
    return "udp:" + r.data + ":True"
}

def main() {
    l = net.listen_on("127.0.0.1", 0)
    print("listen", l.ok)
    if not l.ok {
        return
    }
    l.listener.set_nonblocking(True)
    port = l.listener.local_port()

    tasks = List[Task[str]]()
    tasks.push(server_side(l.listener.fd, 1000))
    tasks.push(client_side(port, 1000))
    results = asyncio.run(asyncio.gather(tasks))
    print("tcp_results", results.get(0), results.get(1))

    c2 = net.connect_to("127.0.0.1", port)
    a2 = l.listener.accept()
    if c2.ok and a2.ok {
        print("timeout_result", asyncio.run(recv_timeout(a2.stream.fd)))
        print("cancel_result", asyncio.run(cancel_orchestrator(a2.stream.fd)))
        a2.stream.close()
        c2.stream.close()
    } else {
        print("timeout_setup_failed")
    }
    l.listener.close()

    ua = udp.open("127.0.0.1:0")
    ub = udp.open("127.0.0.1:0")
    if ua.ok and ub.ok {
        print("udp_result", asyncio.run(udp_exchange(ua.sock, ub.sock)))
        ua.sock.close()
        ub.sock.close()
    } else {
        print("udp_setup_failed")
    }

    bad = asyncio.run(net_async.connect_to("127.0.0.1", 1, 200))
    print("refused", bad.ok, bad.error.len() > 0)
}
