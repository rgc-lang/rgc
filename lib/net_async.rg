# RGC standard library: net_async
#
# Await-friendly TCP/UDP wrappers over non-blocking sockets. Readiness is waited
# through the event loop (`event.wait_fd`, epoll) in 50 ms slices so cancellation
# and total timeouts are observed. The task itself still runs on its own thread
# (thread-per-task); the event loop only drives fd readiness, it is not a coroutine
# scheduler.
#
# Usage:
#   import net
#   import net_async
#   import asyncio
#   ...
#   c = await net_async.connect_to("127.0.0.1", port, 1000)
#   z = await net_async.send(c.stream.fd, "ping", 1000)
#   r = await net_async.recv(c.stream.fd, 64, 1000)
#
# Semantics:
#   - timeout_ms < 0 waits indefinitely; 0 polls once (likely timeout).
#   - Errors: "timeout" / "cancelled" are reported through the result classes.
#   - Socket fds are switched to non-blocking mode by these wrappers.
#   - TCP recv returns on peer close (ok=True, empty value); TCP send is looped
#     until all bytes are written or an error/timeout occurs.

import net
import udp
import event
import asyncio
import time
import bytes

public class AsyncWait {
    ok: bool
    timeout: bool
    cancelled: bool
    error: str
}

def empty_stream() -> TcpStream {
    s = TcpStream()
    s.fd = -1
    s.timeout_ms = 0
    return s
}

def fail_connect(msg: str) -> TcpConnect {
    r = TcpConnect()
    r.ok = False
    r.error = msg
    r.stream = empty_stream()
    return r
}

def fail_accept(msg: str) -> TcpAccept {
    r = TcpAccept()
    r.ok = False
    r.again = False
    r.error = msg
    r.stream = empty_stream()
    return r
}

def fail_recv_bytes(msg: str) -> TcpRecvBytes {
    r = TcpRecvBytes()
    r.ok = False
    r.again = False
    r.error = msg
    r.value = bytes.bytes_new(0)
    return r
}

def fail_recv(msg: str) -> TcpRecv {
    r = TcpRecv()
    r.ok = False
    r.again = False
    r.error = msg
    r.value = ""
    return r
}

def ok_send(sent: int) -> TcpSend {
    r = TcpSend()
    r.ok = True
    r.again = False
    r.error = ""
    r.sent = sent
    return r
}

def fail_send(msg: str, sent: int) -> TcpSend {
    r = TcpSend()
    r.ok = False
    r.again = False
    r.error = msg
    r.sent = sent
    return r
}

def fail_udp_recv(msg: str) -> UdpRecv {
    r = UdpRecv()
    r.ok = False
    r.again = False
    r.error = msg
    r.data = ""
    r.data_bytes = bytes.bytes_new(0)
    r.host = ""
    r.port = 0
    return r
}

def fail_udp_send(msg: str) -> UdpSend {
    r = UdpSend()
    r.ok = False
    r.again = False
    r.error = msg
    r.sent = 0
    return r
}

def expired(start: float, timeout_ms: int) -> bool {
    if timeout_ms < 0 {
        return False
    }
    return time.now_monotonic() - start >= timeout_ms / 1000.0
}

# Debug/probe helper: same cancellation source the wait loops use.
public def is_cancelled() -> bool {
    return asyncio.cancelled()
}

# Wait one 50 ms slice for fd readiness, checking cancellation first.
def wait_ready(fd: int, events: int) -> AsyncWait {
    r = AsyncWait()
    r.ok = False
    r.timeout = False
    r.cancelled = False
    r.error = ""
    if fd < 0 {
        r.error = "socket is closed"
        return r
    }
    if asyncio.cancelled() {
        r.cancelled = True
        r.error = "cancelled"
        return r
    }
    n = event.wait_fd(fd, events, 50)
    if n > 0 {
        r.ok = True
    } elif n == 0 {
        r.timeout = True
    } else {
        r.error = "event wait failed"
    }
    return r
}

public async def connect_to(host: str, port: int, timeout_ms: int) -> TcpConnect {
    cs = net.connect_start_to(host, port)
    if not cs.ok {
        return fail_connect(cs.error)
    }
    fd = cs.stream.fd
    if not cs.pending {
        s = TcpStream()
        s.fd = fd
        s.timeout_ms = 0
        return net.connect_finish(s)
    }
    start = time.now_monotonic()
    while True {
        if expired(start, timeout_ms) {
            net.close_fd(fd)
            return fail_connect("timeout")
        }
        w = wait_ready(fd, event.ev_out())
        if w.cancelled {
            net.close_fd(fd)
            return fail_connect("cancelled")
        }
        if not w.ok and not w.timeout {
            net.close_fd(fd)
            return fail_connect(w.error)
        }
        if w.ok {
            break
        }
    }
    s = TcpStream()
    s.fd = fd
    s.timeout_ms = 0
    return net.connect_finish(s)
}

public async def accept(listener_fd: int, timeout_ms: int) -> TcpAccept {
    l = TcpListener()
    l.fd = listener_fd
    l.timeout_ms = 0
    l.unix_path = ""
    l.set_nonblocking(True)
    start = time.now_monotonic()
    while True {
        if expired(start, timeout_ms) {
            return fail_accept("timeout")
        }
        w = wait_ready(listener_fd, event.ev_in())
        if w.cancelled {
            return fail_accept("cancelled")
        }
        if not w.ok and not w.timeout {
            return fail_accept(w.error)
        }
        if w.ok {
            a = l.try_accept()
            if not a.ok {
                return a
            }
            if not a.again {
                return a
            }
        }
    }
    return fail_accept("timeout")
}

def recv_bytes_sync(fd: int, max: int, timeout_ms: int) -> TcpRecvBytes {
    s = TcpStream()
    s.fd = fd
    s.timeout_ms = 0
    s.set_nonblocking(True)
    start = time.now_monotonic()
    while True {
        if expired(start, timeout_ms) {
            return fail_recv_bytes("timeout")
        }
        w = wait_ready(fd, event.ev_in())
        if w.cancelled {
            return fail_recv_bytes("cancelled")
        }
        if not w.ok and not w.timeout {
            return fail_recv_bytes(w.error)
        }
        if w.ok {
            r = s.try_recv_bytes(max)
            if not r.ok {
                return r
            }
            if not r.again {
                return r
            }
        }
    }
    return fail_recv_bytes("timeout")
}

public async def recv_bytes(fd: int, max: int, timeout_ms: int) -> TcpRecvBytes {
    return recv_bytes_sync(fd, max, timeout_ms)
}

public async def recv(fd: int, max: int, timeout_ms: int) -> TcpRecv {
    b = recv_bytes_sync(fd, max, timeout_ms)
    r = TcpRecv()
    r.ok = b.ok
    r.again = b.again
    r.error = b.error
    r.value = ""
    if b.ok and b.value.len > 0 {
        r.value = b.value.to_str()
    }
    return r
}

public async def send(fd: int, data: str, timeout_ms: int) -> TcpSend {
    s = TcpStream()
    s.fd = fd
    s.timeout_ms = 0
    s.set_nonblocking(True)
    total_len = data.len()
    if total_len == 0 {
        return ok_send(0)
    }
    total = 0
    start = time.now_monotonic()
    while total < total_len {
        if expired(start, timeout_ms) {
            return fail_send("timeout", total)
        }
        part = data.slice(total, total_len)
        r = s.try_send(part)
        if not r.ok {
            r.sent = r.sent + total
            return r
        }
        total = total + r.sent
        if total >= total_len {
            return ok_send(total)
        }
        if r.sent == 0 and not r.again {
            return fail_send("connection closed", total)
        }
        if r.again {
            w = wait_ready(fd, event.ev_out())
            if w.cancelled {
                return fail_send("cancelled", total)
            }
            if not w.ok and not w.timeout {
                return fail_send(w.error, total)
            }
        }
    }
    return ok_send(total)
}

public async def udp_recv(fd: int, max: int, timeout_ms: int) -> UdpRecv {
    s = UdpSocket()
    s.fd = fd
    s.family = 2
    s.set_nonblocking(True)
    start = time.now_monotonic()
    while True {
        if expired(start, timeout_ms) {
            return fail_udp_recv("timeout")
        }
        w = wait_ready(fd, event.ev_in())
        if w.cancelled {
            return fail_udp_recv("cancelled")
        }
        if not w.ok and not w.timeout {
            return fail_udp_recv(w.error)
        }
        if w.ok {
            r = s.try_recv_from(max)
            if not r.ok {
                return r
            }
            if not r.again {
                return r
            }
        }
    }
    return fail_udp_recv("timeout")
}

public async def udp_send(fd: int, family: int, data: str, host: str,
                          port: int, timeout_ms: int) -> UdpSend {
    s = UdpSocket()
    s.fd = fd
    s.family = family
    s.set_nonblocking(True)
    start = time.now_monotonic()
    while True {
        if expired(start, timeout_ms) {
            return fail_udp_send("timeout")
        }
        r = s.try_send_to(data, host, port)
        if r.ok and not r.again {
            return r
        }
        if not r.ok and not r.again {
            return r
        }
        w = wait_ready(fd, event.ev_out())
        if w.cancelled {
            return fail_udp_send("cancelled")
        }
        if not w.ok and not w.timeout {
            return fail_udp_send(w.error)
        }
    }
    return fail_udp_send("timeout")
}
