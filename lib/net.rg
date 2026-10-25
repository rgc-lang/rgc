# RGC standard library: net
#
# Synchronous TCP: getaddrinfo resolution (IPv4 / IPv6 / hostnames), Unix domain sockets,
# connect/read/write timeouts, binary-safe send/receive. Calls libc directly via extern defs underneath.
# The language does not yet support Result[custom types]; results are carried by classes with ok/error fields.
#
# Usage:
#   import net
#   c = net.connect("127.0.0.1:8080")
#   if c.ok {
#       s = c.stream
#       n = s.send("GET / HTTP/1.0\r\n\r\n")
#       r = s.recv(4096)
#       if r.ok { print(r.value) } else { print(r.error) }
#       s.close()
#   } else {
#       print("connect failed:", c.error)
#   }
#
# Semantics:
#   - Address format is "host:port"; IPv6 literals use "[::1]:8080"; hostnames are resolved by getaddrinfo.
#   - connect times out after 10s by default; use connect_timeout / connect_to_timeout to override.
#   - send blocks until all bytes are written or an error occurs, returning the actual byte count.
#   - recv reads at most max bytes; on peer close ok=True, value=""; on timeout/error ok=False.
#   - recv_bytes/send_bytes are binary-safe (explicit lengths); the string versions follow C string semantics.
#   - set_timeout(ms) sets read/write timeouts (SO_RCVTIMEO/SO_SNDTIMEO); 0 means blocking.
#   - Unix domain sockets: connect_unix/listen_unix; paths starting with '@' use the Linux abstract namespace.
#
# Note: receive buffers and returned strings are heap-allocated; there is currently no GC (same as io/json).

import bytes

extern def socket(domain: int, kind: int, protocol: int) -> int
extern def close(fd: int) -> int
extern def accept(fd: int, addr: str, addrlen: str) -> int
extern def send(fd: int, buf: str, len: int, flags: int) -> int
extern def recv(fd: int, buf: str, len: int, flags: int) -> int
extern def setsockopt(fd: int, level: int, optname: int, optval: str, optlen: int) -> int
extern def getsockopt(fd: int, level: int, optname: int, optval: str, optlen: str) -> int
extern def getsockname(fd: int, addr: str, addrlen: str) -> int
extern def getpeername(fd: int, addr: str, addrlen: str) -> int
extern def poll(fds: str, nfds: int, timeout: int) -> int
extern def fcntl(fd: int, cmd: int, arg: int) -> int
extern def getaddrinfo(node: str, service: str, hints: str, res: str) -> int
extern def freeaddrinfo(res: str) -> None
extern def gai_strerror(code: int) -> str
extern def getnameinfo(addr: str, addrlen: int, host: str, hostlen: int,
                       serv: str, servlen: int, flags: int) -> int
extern def lstat(path: str, st: str) -> int
extern def unlink(path: str) -> int
extern def shutdown(fd: int, how: int) -> int
extern def __errno_location() -> str
extern def strerror(code: int) -> str

public class TcpRecv {
    ok: bool
    again: bool
    error: str
    value: str
}

public class TcpRecvBytes {
    ok: bool
    again: bool
    error: str
    value: Bytes
}

public class TcpSend {
    ok: bool
    again: bool
    error: str
    sent: int
}

public class TcpStream {
    fd: int
    timeout_ms: int

    def send(self, data: str) -> int {
        return self.send_mem(data, data.len())
    }

    def send_bytes(self, data: @Bytes) -> int {
        return self.send_mem(data.data, data.len)
    }

    def send_mem(self, p: str, n: int) -> int {
        if self.fd < 0 {
            return 0
        }
        total = 0
        while total < n {
            base = int_to_ptr(ptr_to_int(p) + total)
            k = send(self.fd, base, n - total, 16384)   # MSG_NOSIGNAL
            if k < 0 {
                e = errno_code()
                if e == 4 {   # EINTR
                    continue
                }
                return total
            }
            if k == 0 {
                return total
            }
            total = total + k
        }
        return total
    }

    def recv(self, max: int) -> TcpRecv {
        r = TcpRecv()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = ""
        b = self.recv_bytes(max)
        if not b.ok {
            r.ok = False
            r.error = b.error
            return r
        }
        if b.value.len == 0 {
            e = errno_code()
            if e != 0 {
                r.ok = False
                r.error = error_text(e)
            }
            return r
        }
        r.value = b.value.to_str()
        return r
    }

    def recv_bytes(self, max: int) -> TcpRecvBytes {
        r = TcpRecvBytes()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = bytes.bytes_new(0)
        if self.fd < 0 {
            r.ok = False
            r.error = "socket is closed"
            return r
        }
        if max <= 0 {
            return r
        }
        b = bytes.bytes_new(max)
        while True {
            set_errno(0)
            n = recv(self.fd, b.data, max, 0)
            if n < 0 {
                e = errno_code()
                if e == 4 {   # EINTR
                    continue
                }
                r.ok = False
                r.error = error_text(e)
                return r
            }
            b.len = n
            r.value = b
            return r
        }
    }

    # Non-blocking read: ok=True, again=True when no data; on peer close ok=True, again=False, empty value.
    def try_recv_bytes(self, max: int) -> TcpRecvBytes {
        r = TcpRecvBytes()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = bytes.bytes_new(0)
        if self.fd < 0 {
            r.ok = False
            r.error = "socket is closed"
            return r
        }
        if max <= 0 {
            return r
        }
        b = bytes.bytes_new(max)
        while True {
            set_errno(0)
            n = recv(self.fd, b.data, max, 0)
            if n < 0 {
                e = errno_code()
                if e == 4 {   # EINTR
                    continue
                }
                if e == 11 {   # EAGAIN / EWOULDBLOCK
                    r.again = True
                    return r
                }
                r.ok = False
                r.error = error_text(e)
                return r
            }
            b.len = n
            r.value = b
            return r
        }
    }

    def try_recv(self, max: int) -> TcpRecv {
        r = TcpRecv()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = ""
        b = self.try_recv_bytes(max)
        r.again = b.again
        if not b.ok {
            r.ok = False
            r.error = b.error
            return r
        }
        if b.value.len == 0 {
            return r
        }
        r.value = b.value.to_str()
        return r
    }

    # Non-blocking send: writes as many bytes as possible; again=True means the kernel buffer is full, wait for writability.
    def try_send(self, data: str) -> TcpSend {
        return self.try_send_mem(data, data.len())
    }

    def try_send_bytes(self, data: @Bytes) -> TcpSend {
        return self.try_send_mem(data.data, data.len)
    }

    def try_send_mem(self, p: str, n: int) -> TcpSend {
        r = TcpSend()
        r.ok = True
        r.again = False
        r.error = ""
        r.sent = 0
        if self.fd < 0 {
            r.ok = False
            r.error = "socket is closed"
            return r
        }
        total = 0
        while total < n {
            base = int_to_ptr(ptr_to_int(p) + total)
            k = send(self.fd, base, n - total, 16384)   # MSG_NOSIGNAL
            if k < 0 {
                e = errno_code()
                if e == 4 {   # EINTR
                    continue
                }
                if e == 11 {   # EAGAIN / EWOULDBLOCK
                    r.again = True
                    r.sent = total
                    return r
                }
                r.ok = False
                r.error = error_text(e)
                r.sent = total
                return r
            }
            if k == 0 {
                r.sent = total
                return r
            }
            total = total + k
        }
        r.sent = total
        return r
    }

    def set_nonblocking(self, on: bool) {
        fd_nonblocking(self.fd, on)
    }

    def set_timeout(self, ms: int) {
        self.timeout_ms = ms
        set_socket_timeout(self.fd, 20, ms)   # SO_RCVTIMEO
        set_socket_timeout(self.fd, 21, ms)   # SO_SNDTIMEO
    }

    def shutdown_write(self) {
        if self.fd >= 0 {
            shutdown(self.fd, 1)   # SHUT_WR
        }
    }

    def local_port(self) -> int {
        return fd_local_port(self.fd)
    }

    def peer_host(self) -> str {
        return fd_peer_host(self.fd)
    }

    def peer_port(self) -> int {
        return fd_peer_port(self.fd)
    }

    def close(self) {
        if self.fd >= 0 {
            close(self.fd)
            self.fd = -1
        }
    }
}

public class TcpAccept {
    ok: bool
    again: bool
    error: str
    stream: TcpStream
}

public class TcpListener {
    fd: int
    timeout_ms: int
    unix_path: str

    def accept(self) -> TcpAccept {
        ms = -1
        if self.timeout_ms > 0 {
            ms = self.timeout_ms
        }
        return self.accept_timeout(ms)
    }

    def accept_timeout(self, ms: int) -> TcpAccept {
        r = TcpAccept()
        r.ok = False
        r.again = False
        r.error = ""
        r.stream = empty_stream()
        if self.fd < 0 {
            r.error = "listener is closed"
            return r
        }
        w = wait_fd(self.fd, 1, ms)   # POLLIN
        if w <= 0 {
            if w == 0 {
                r.error = "timeout"
            } else {
                r.error = error_text(errno_code())
            }
            return r
        }
        fd = accept(self.fd, ptr_null(), ptr_null())
        if fd < 0 {
            r.error = error_text(errno_code())
            if r.error.len() == 0 {
                r.error = "accept failed"
            }
            return r
        }
        s = TcpStream()
        s.fd = fd
        s.timeout_ms = self.timeout_ms
        r.stream = s
        r.ok = True
        return r
    }

    # Non-blocking accept: ok=True, again=True when no pending connection.
    def try_accept(self) -> TcpAccept {
        r = TcpAccept()
        r.ok = False
        r.again = False
        r.error = ""
        r.stream = empty_stream()
        if self.fd < 0 {
            r.error = "listener is closed"
            return r
        }
        while True {
            set_errno(0)
            fd = accept(self.fd, ptr_null(), ptr_null())
            if fd < 0 {
                e = errno_code()
                if e == 4 {   # EINTR
                    continue
                }
                if e == 11 {   # EAGAIN / EWOULDBLOCK
                    r.ok = True
                    r.again = True
                    return r
                }
                r.error = error_text(e)
                if r.error.len() == 0 {
                    r.error = "accept failed"
                }
                return r
            }
            s = TcpStream()
            s.fd = fd
            s.timeout_ms = self.timeout_ms
            r.stream = s
            r.ok = True
            return r
        }
    }

    def set_nonblocking(self, on: bool) {
        fd_nonblocking(self.fd, on)
    }

    def set_timeout(self, ms: int) {
        self.timeout_ms = ms
    }

    def local_port(self) -> int {
        return fd_local_port(self.fd)
    }

    def close(self) {
        if self.fd >= 0 {
            close(self.fd)
            self.fd = -1
            if self.unix_path.len() > 0 and not is_abstract_path(self.unix_path) {
                unlink(self.unix_path)
            }
        }
    }
}

public class TcpConnect {
    ok: bool
    error: str
    stream: TcpStream
}

public class TcpConnectStart {
    ok: bool
    pending: bool
    error: str
    stream: TcpStream
}

public class TcpListen {
    ok: bool
    error: str
    listener: TcpListener
}

public class SockAddr {
    sa: str
    len: int
    family: int
}

class AddrParts {
    ok: bool
    error: str
    host: str
    port: int
}

# ---------------------------------------------------------------------------
# errno / low-level helpers
# ---------------------------------------------------------------------------

public def errno_code() -> int {
    ep = __errno_location()
    return buf_get32(ep, 0)
}

def set_errno(code: int) {
    ep = __errno_location()
    buf_set32(ep, 0, code)
}

public def error_text(code: int) -> str {
    if code == 0 {
        return ""
    }
    if code == 11 or code == 110 {
        return "timeout"
    }
    return strerror(code)
}

public def close_fd(fd: int) {
    if fd >= 0 {
        close(fd)
    }
}

# Poll wait: events are POLLIN(1)/POLLOUT(4). Returns the poll result; errno is valid when < 0.
public def wait_fd(fd: int, events: int, timeout_ms: int) -> int {
    p = buf_alloc(8)
    buf_zero(p, 8)
    buf_set32(p, 0, fd)
    buf_set8(p, 4, events % 256)
    buf_set8(p, 5, events / 256 % 256)
    while True {
        rc = poll(p, 1, timeout_ms)
        if rc < 0 and errno_code() == 4 {   # EINTR
            continue
        }
        buf_free(p)
        return rc
    }
}

# Idle-connection liveness check: returns True when the peer closed (FIN/error), without consuming data.
public def fd_is_closed(fd: int) -> bool {
    if fd < 0 {
        return True
    }
    p = buf_alloc(8)
    buf_zero(p, 8)
    buf_set32(p, 0, fd)
    buf_set8(p, 4, 1)   # POLLIN
    rc = poll(p, 1, 0)
    buf_free(p)
    if rc < 0 {
        return True
    }
    if rc == 0 {
        return False
    }
    b = buf_alloc(1)
    set_errno(0)
    n = recv(fd, b, 1, 66)   # MSG_PEEK | MSG_DONTWAIT
    e = errno_code()
    buf_free(b)
    if n == 0 {
        return True
    }
    if n < 0 and e != 11 and e != 4 {   # EAGAIN / EINTR
        return True
    }
    return False
}

public def set_socket_timeout(fd: int, optname: int, ms: int) {
    if fd < 0 {
        return
    }
    tv = buf_alloc(16)
    buf_zero(tv, 16)
    if ms > 0 {
        buf_set64(tv, 0, ms / 1000)
        buf_set64(tv, 8, ms % 1000 * 1000)
    }
    setsockopt(fd, 1, optname, tv, 16)   # SOL_SOCKET
    buf_free(tv)
}

# Toggle O_NONBLOCK. Call before non-blocking connect/accept/recv/send;
# connect_start automatically puts the socket into non-blocking mode.
public def set_nonblocking(fd: int, on: bool) {
    fd_nonblocking(fd, on)
}

def fd_nonblocking(fd: int, on: bool) {
    if fd < 0 {
        return
    }
    fl = fcntl(fd, 3, 0)   # F_GETFL
    if fl < 0 {
        return
    }
    if on {
        fcntl(fd, 4, fl | 2048)   # F_SETFL / O_NONBLOCK
    } else {
        fcntl(fd, 4, fl & -2049)
    }
}

def socket_error(fd: int) -> int {
    v = buf_alloc(4)
    l = buf_alloc(4)
    buf_set32(v, 0, 0)
    buf_set32(l, 0, 4)
    rc = getsockopt(fd, 1, 4, v, l)   # SOL_SOCKET / SO_ERROR
    e = 0
    if rc == 0 {
        e = buf_get32(v, 0)
    }
    buf_free(v)
    buf_free(l)
    return e
}

# Non-blocking connect with poll timeout; timeout_ms <= 0 means wait indefinitely.
def dial(fd: int, sa: str, salen: int, timeout_ms: int) -> int {
    fl = fcntl(fd, 3, 0)   # F_GETFL
    if fl < 0 {
        return -1
    }
    fcntl(fd, 4, fl + 2048)   # F_SETFL / O_NONBLOCK
    rc = tcp_connect_fd(fd, sa, salen)
    if rc == 0 {
        fcntl(fd, 4, fl)
        return 0
    }
    e = errno_code()
    if e != 115 {   # EINPROGRESS
        fcntl(fd, 4, fl)
        set_errno(e)
        return -1
    }
    ms = timeout_ms
    if ms <= 0 {
        ms = -1
    }
    w = wait_fd(fd, 4, ms)   # POLLOUT
    if w <= 0 {
        fcntl(fd, 4, fl)
        if w == 0 {
            set_errno(110)   # ETIMEDOUT
        }
        return -1
    }
    se = socket_error(fd)
    fcntl(fd, 4, fl)
    if se != 0 {
        set_errno(se)
        return -1
    }
    return 0
}

# ---------------------------------------------------------------------------
# sockaddr / addrinfo
# ---------------------------------------------------------------------------

def hints_alloc(socktype: int, passive: bool) -> str {
    h = buf_alloc(48)
    buf_zero(h, 48)
    if passive {
        buf_set32(h, 0, 1)   # AI_PASSIVE
    }
    buf_set32(h, 8, socktype)
    return h
}

def ai_family(p: str) -> int {
    return buf_get32(p, 4)
}

def ai_socktype(p: str) -> int {
    return buf_get32(p, 8)
}

def ai_protocol(p: str) -> int {
    return buf_get32(p, 12)
}

def ai_addrlen(p: str) -> int {
    return buf_get32(p, 16)
}

def ai_addr(p: str) -> str {
    return int_to_ptr(buf_get64(p, 24))
}

def ai_next(p: str) -> str {
    return int_to_ptr(buf_get64(p, 40))
}

def sa_family(sa: str) -> int {
    return buf_get8(sa, 0) + buf_get8(sa, 1) * 256
}

def sa_port(sa: str) -> int {
    f = sa_family(sa)
    if f == 2 or f == 10 {   # AF_INET / AF_INET6
        return buf_get8(sa, 2) * 256 + buf_get8(sa, 3)
    }
    return -1
}

def cstr_at(p: str, max: int) -> str {
    n = 0
    while n < max {
        if buf_get8(p, n) == 0 {
            break
        }
        n = n + 1
    }
    return buf_to_str(p, n)
}

def fd_local_port(fd: int) -> int {
    if fd < 0 {
        return -1
    }
    sa = buf_alloc(128)
    lp = buf_alloc(4)
    buf_zero(sa, 128)
    buf_set32(lp, 0, 128)
    rc = getsockname(fd, sa, lp)
    p = -1
    if rc == 0 {
        p = sa_port(sa)
    }
    buf_free(sa)
    buf_free(lp)
    return p
}

def fd_peer_name(fd: int, want_port: bool) -> str {
    if fd < 0 {
        return ""
    }
    sa = buf_alloc(128)
    lp = buf_alloc(4)
    buf_zero(sa, 128)
    buf_set32(lp, 0, 128)
    rc = getpeername(fd, sa, lp)
    out = ""
    if rc == 0 {
        hb = buf_alloc(256)
        sb = buf_alloc(32)
        buf_zero(hb, 256)
        buf_zero(sb, 32)
        r2 = getnameinfo(sa, buf_get32(lp, 0), hb, 256, sb, 32, 3)   # numeric form
        if r2 == 0 {
            if want_port {
                out = cstr_at(sb, 32)
            } else {
                out = cstr_at(hb, 256)
            }
        }
        buf_free(hb)
        buf_free(sb)
    }
    buf_free(sa)
    buf_free(lp)
    return out
}

def fd_peer_host(fd: int) -> str {
    return fd_peer_name(fd, False)
}

def fd_peer_port(fd: int) -> int {
    s = fd_peer_name(fd, True)
    if s.len() == 0 {
        return -1
    }
    r = s.to_int()
    if r.is_err() {
        return -1
    }
    return r.unwrap()
}

# ---------------------------------------------------------------------------
# Address resolution
# ---------------------------------------------------------------------------

def finish_addr(host: str, port_text: str) -> AddrParts {
    r = AddrParts()
    r.ok = False
    r.error = ""
    r.host = ""
    r.port = 0
    if host.len() == 0 {
        r.error = "address must be host:port"
        return r
    }
    if port_text.len() == 0 {
        r.error = "address must be host:port"
        return r
    }
    pr = port_text.to_int()
    if pr.is_err() {
        r.error = "invalid port"
        return r
    }
    p = pr.unwrap()
    if p < 0 or p > 65535 {
        r.error = "port out of range"
        return r
    }
    r.host = host
    r.port = p
    r.ok = True
    return r
}

def parse_addr(addr: str) -> AddrParts {
    n = addr.len()
    if n == 0 {
        r = AddrParts()
        r.ok = False
        r.error = "address must be host:port"
        r.host = ""
        r.port = 0
        return r
    }
    # [IPv6]:port
    if addr.char_at(0) == 91 {   # '['
        i = 1
        while i < n and addr.char_at(i) != 93 {   # ']'
            i = i + 1
        }
        if i >= n or i + 1 >= n or addr.char_at(i + 1) != 58 {   # ':'
            r0 = AddrParts()
            r0.ok = False
            r0.error = "address must be host:port"
            r0.host = ""
            r0.port = 0
            return r0
        }
        return finish_addr(addr.slice(1, i), addr.slice(i + 2, n))
    }
    i = n - 1
    while i >= 0 {
        if addr.char_at(i) == 58 {
            host = addr.slice(0, i)
            if host.contains(":") {
                r1 = AddrParts()
                r1.ok = False
                r1.error = "address must be host:port"
                r1.host = ""
                r1.port = 0
                return r1
            }
            return finish_addr(host, addr.slice(i + 1, n))
        }
        i = i - 1
    }
    r2 = AddrParts()
    r2.ok = False
    r2.error = "address must be host:port"
    r2.host = ""
    r2.port = 0
    return r2
}

# Resolve a host into a list of numeric addresses (IPv4/IPv6, deduplicated).
public def resolve(host: str) -> List[str] {
    out = List[str]()
    if host.len() == 0 {
        return out
    }
    hints = hints_alloc(1, False)   # SOCK_STREAM
    resp = buf_alloc(8)
    buf_zero(resp, 8)
    rc = getaddrinfo(host, ptr_null(), hints, resp)
    if rc == 0 {
        head = int_to_ptr(buf_get64(resp, 0))
        cur = head
        while not ptr_is_null(cur) {
            sa = ai_addr(cur)
            hb = buf_alloc(256)
            sb = buf_alloc(32)
            buf_zero(hb, 256)
            buf_zero(sb, 32)
            r2 = getnameinfo(sa, ai_addrlen(cur), hb, 256, sb, 32, 3)
            if r2 == 0 {
                s = cstr_at(hb, 256)
                if not out.contains(s) {
                    out.push(s)
                }
            }
            buf_free(hb)
            buf_free(sb)
            cur = ai_next(cur)
        }
        freeaddrinfo(head)
    }
    buf_free(hints)
    buf_free(resp)
    return out
}

def copy_sockaddr(p: str, n: int) -> str {
    b = buf_alloc(n)
    i = 0
    while i < n {
        buf_set8(b, i, buf_get8(p, i))
        i = i + 1
    }
    return b
}

# Resolve host/service into standalone sockaddr copies (IPv4/IPv6), for modules needing raw addresses like UDP.
# socktype: 1=SOCK_STREAM, 2=SOCK_DGRAM; with passive=True, host may be empty (wildcard address).
public def resolve_sockaddrs(host: str, port: int, socktype: int,
                             passive: bool) -> List[SockAddr] {
    out = List[SockAddr]()
    hints = hints_alloc(socktype, passive)
    resp = buf_alloc(8)
    buf_zero(resp, 8)
    node = host
    if host.len() == 0 {
        node = ptr_null()
    }
    rc = getaddrinfo(node, to_string(port), hints, resp)
    if rc == 0 {
        head = int_to_ptr(buf_get64(resp, 0))
        cur = head
        while not ptr_is_null(cur) {
            n = ai_addrlen(cur)
            a = SockAddr()
            a.sa = copy_sockaddr(ai_addr(cur), n)
            a.len = n
            a.family = ai_family(cur)
            out.push(a)
            cur = ai_next(cur)
        }
        freeaddrinfo(head)
    }
    buf_free(hints)
    buf_free(resp)
    return out
}

public def free_sockaddrs(addrs: @List[SockAddr]) {
    i = 0
    while i < addrs.len() {
        buf_free(addrs.get(i).sa)
        i = i + 1
    }
}

public def sockaddr_port(sa: str) -> int {
    return sa_port(sa)
}

public def sockaddr_host(sa: str, salen: int) -> str {
    hb = buf_alloc(256)
    sb = buf_alloc(32)
    buf_zero(hb, 256)
    buf_zero(sb, 32)
    rc = getnameinfo(sa, salen, hb, 256, sb, 32, 1)   # NI_NUMERICHOST
    out = ""
    if rc == 0 {
        out = cstr_at(hb, 256)
    }
    buf_free(hb)
    buf_free(sb)
    return out
}

# ---------------------------------------------------------------------------
# Construct results
# ---------------------------------------------------------------------------

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

def ok_connect(fd: int, timeout_ms: int) -> TcpConnect {
    r = TcpConnect()
    r.ok = True
    r.error = ""
    s = TcpStream()
    s.fd = fd
    s.timeout_ms = timeout_ms
    if timeout_ms > 0 {
        set_socket_timeout(fd, 20, timeout_ms)
        set_socket_timeout(fd, 21, timeout_ms)
    }
    r.stream = s
    return r
}

def fail_connect_start(msg: str) -> TcpConnectStart {
    r = TcpConnectStart()
    r.ok = False
    r.pending = False
    r.error = msg
    r.stream = empty_stream()
    return r
}

def ok_connect_start(fd: int, pending: bool) -> TcpConnectStart {
    r = TcpConnectStart()
    r.ok = True
    r.pending = pending
    r.error = ""
    s = TcpStream()
    s.fd = fd
    s.timeout_ms = 0
    r.stream = s
    return r
}

def fail_listen(msg: str) -> TcpListen {
    r = TcpListen()
    r.ok = False
    r.error = msg
    l = TcpListener()
    l.fd = -1
    l.timeout_ms = 0
    l.unix_path = ""
    r.listener = l
    return r
}

def ok_listen(fd: int, unix_path: str) -> TcpListen {
    r = TcpListen()
    r.ok = True
    r.error = ""
    l = TcpListener()
    l.fd = fd
    l.timeout_ms = 0
    l.unix_path = unix_path
    r.listener = l
    return r
}

# ---------------------------------------------------------------------------
# TCP connect / listen
# ---------------------------------------------------------------------------

public def connect_to_timeout(host: str, port: int, timeout_ms: int) -> TcpConnect {
    if host.len() == 0 {
        return fail_connect("host is empty")
    }
    if port < 0 or port > 65535 {
        return fail_connect("port out of range")
    }
    svc = to_string(port)
    hints = hints_alloc(1, False)   # SOCK_STREAM
    resp = buf_alloc(8)
    buf_zero(resp, 8)
    rc = getaddrinfo(host, svc, hints, resp)
    if rc != 0 {
        msg = gai_strerror(rc)
        buf_free(hints)
        buf_free(resp)
        return fail_connect(msg)
    }
    head = int_to_ptr(buf_get64(resp, 0))
    cur = head
    last_err = 0
    fd = -1
    while not ptr_is_null(cur) {
        fam = ai_family(cur)
        typ = ai_socktype(cur)
        proto = ai_protocol(cur)
        nfd = socket(fam, typ, proto)
        if nfd >= 0 {
            if dial(nfd, ai_addr(cur), ai_addrlen(cur), timeout_ms) == 0 {
                fd = nfd
                last_err = 0
                cur = ptr_null()
            } else {
                last_err = errno_code()
                close(nfd)
                cur = ai_next(cur)
            }
        } else {
            last_err = errno_code()
            cur = ai_next(cur)
        }
    }
    freeaddrinfo(head)
    buf_free(hints)
    buf_free(resp)
    if fd < 0 {
        msg = "connect failed"
        if last_err != 0 {
            msg = error_text(last_err)
        }
        return fail_connect(msg)
    }
    return ok_connect(fd, timeout_ms)
}

public def connect_to(host: str, port: int) -> TcpConnect {
    return connect_to_timeout(host, port, 10000)
}

public def connect_timeout(addr: str, timeout_ms: int) -> TcpConnect {
    p = parse_addr(addr)
    if not p.ok {
        return fail_connect(p.error)
    }
    return connect_to_timeout(p.host, p.port, timeout_ms)
}

public def connect(addr: str) -> TcpConnect {
    p = parse_addr(addr)
    if not p.ok {
        return fail_connect(p.error)
    }
    return connect_to_timeout(p.host, p.port, 10000)
}

# Non-blocking connect: pending=False when completed immediately; pending=True while in progress,
# then call connect_finish once the fd is writable (event.ev_out) to get the result.
public def connect_start_to(host: str, port: int) -> TcpConnectStart {
    if host.len() == 0 {
        return fail_connect_start("host is empty")
    }
    if port < 0 or port > 65535 {
        return fail_connect_start("port out of range")
    }
    svc = to_string(port)
    hints = hints_alloc(1, False)   # SOCK_STREAM
    resp = buf_alloc(8)
    buf_zero(resp, 8)
    rc = getaddrinfo(host, svc, hints, resp)
    if rc != 0 {
        msg = gai_strerror(rc)
        buf_free(hints)
        buf_free(resp)
        return fail_connect_start(msg)
    }
    head = int_to_ptr(buf_get64(resp, 0))
    cur = head
    last_err = 0
    fd = -1
    pending = False
    done = False
    while not ptr_is_null(cur) {
        fam = ai_family(cur)
        typ = ai_socktype(cur)
        proto = ai_protocol(cur)
        nfd = socket(fam, typ, proto)
        if nfd >= 0 {
            fd_nonblocking(nfd, True)
            crc = tcp_connect_fd(nfd, ai_addr(cur), ai_addrlen(cur))
            if crc == 0 {
                fd = nfd
                pending = False
                last_err = 0
                done = True
            } else {
                e = errno_code()
                if e == 115 {   # EINPROGRESS
                    fd = nfd
                    pending = True
                    last_err = 0
                    done = True
                } else {
                    last_err = e
                    close(nfd)
                }
            }
        } else {
            last_err = errno_code()
        }
        if done {
            cur = ptr_null()
        } else {
            cur = ai_next(cur)
        }
    }
    freeaddrinfo(head)
    buf_free(hints)
    buf_free(resp)
    if fd < 0 {
        msg = "connect failed"
        if last_err != 0 {
            msg = error_text(last_err)
        }
        return fail_connect_start(msg)
    }
    return ok_connect_start(fd, pending)
}

public def connect_start(addr: str) -> TcpConnectStart {
    p = parse_addr(addr)
    if not p.ok {
        return fail_connect_start(p.error)
    }
    return connect_start_to(p.host, p.port)
}

# Finish a non-blocking connect: SO_ERROR == 0 means connected; on failure the fd is closed.
public def connect_finish(s: TcpStream) -> TcpConnect {
    if s.fd < 0 {
        return fail_connect("socket is closed")
    }
    e = socket_error(s.fd)
    if e != 0 {
        close(s.fd)
        s.fd = -1
        return fail_connect(error_text(e))
    }
    r = TcpConnect()
    r.ok = True
    r.error = ""
    r.stream = s
    return r
}

# Listen: port 0 lets the kernel assign an ephemeral port; wildcard addresses use "0.0.0.0" / "::".
public def listen_on(host: str, port: int) -> TcpListen {
    if host.len() == 0 {
        return fail_listen("host is empty")
    }
    if port < 0 or port > 65535 {
        return fail_listen("port out of range")
    }
    svc = to_string(port)
    hints = hints_alloc(1, True)   # SOCK_STREAM + AI_PASSIVE
    resp = buf_alloc(8)
    buf_zero(resp, 8)
    rc = getaddrinfo(host, svc, hints, resp)
    if rc != 0 {
        msg = gai_strerror(rc)
        buf_free(hints)
        buf_free(resp)
        return fail_listen(msg)
    }
    head = int_to_ptr(buf_get64(resp, 0))
    cur = head
    last_err = 0
    fd = -1
    while not ptr_is_null(cur) {
        fam = ai_family(cur)
        typ = ai_socktype(cur)
        proto = ai_protocol(cur)
        nfd = socket(fam, typ, proto)
        if nfd >= 0 {
            opt = buf_alloc(4)
            buf_set32(opt, 0, 1)
            setsockopt(nfd, 1, 2, opt, 4)   # SO_REUSEADDR
            buf_free(opt)
            brc = tcp_bind_fd(nfd, ai_addr(cur), ai_addrlen(cur))
            if brc == 0 {
                lrc = tcp_listen_fd(nfd, 128)
                if lrc == 0 {
                    fd = nfd
                    last_err = 0
                    cur = ptr_null()
                } else {
                    last_err = errno_code()
                    close(nfd)
                    cur = ai_next(cur)
                }
            } else {
                last_err = errno_code()
                close(nfd)
                cur = ai_next(cur)
            }
        } else {
            last_err = errno_code()
            cur = ai_next(cur)
        }
    }
    freeaddrinfo(head)
    buf_free(hints)
    buf_free(resp)
    if fd < 0 {
        msg = "bind failed"
        if last_err != 0 {
            msg = error_text(last_err)
        }
        return fail_listen(msg)
    }
    return ok_listen(fd, "")
}

public def listen(addr: str) -> TcpListen {
    p = parse_addr(addr)
    if not p.ok {
        return fail_listen(p.error)
    }
    return listen_on(p.host, p.port)
}

# ---------------------------------------------------------------------------
# Unix domain sockets
# ---------------------------------------------------------------------------

def is_abstract_path(path: str) -> bool {
    return path.len() > 0 and path.char_at(0) == 64   # '@'
}

def unix_sockaddr(path: str) -> str {
    n = path.len()
    b = buf_alloc(n + 3)
    buf_zero(b, n + 3)
    buf_set8(b, 0, 1)   # AF_UNIX
    i = 0
    if is_abstract_path(path) {
        i = 1
    }
    while i < n {
        off = 2 + i
        if is_abstract_path(path) {
            off = 2 + i - 1
        }
        buf_set8(b, off, path.char_at(i))
        i = i + 1
    }
    return b
}

def unix_sockaddr_len(path: str) -> int {
    n = path.len()
    if is_abstract_path(path) {
        return 2 + n
    }
    return 2 + n + 1
}

def is_socket_file(path: str) -> bool {
    st = buf_alloc(160)
    buf_zero(st, 160)
    rc = lstat(path, st)
    ok = False
    if rc == 0 {
        mode = buf_get32(st, 24) % 65536
        if mode >= 49152 and mode <= 53247 {   # S_IFSOCK
            ok = True
        }
    }
    buf_free(st)
    return ok
}

public def connect_unix_timeout(path: str, timeout_ms: int) -> TcpConnect {
    if path.len() == 0 {
        return fail_connect("socket path is empty")
    }
    if path.len() > 107 {
        return fail_connect("socket path too long")
    }
    fd = socket(1, 1, 0)   # AF_UNIX / SOCK_STREAM
    if fd < 0 {
        return fail_connect(error_text(errno_code()))
    }
    sa = unix_sockaddr(path)
    rc = dial(fd, sa, unix_sockaddr_len(path), timeout_ms)
    e = errno_code()
    buf_free(sa)
    if rc != 0 {
        close(fd)
        msg = "connect failed"
        if e != 0 {
            msg = error_text(e)
        }
        return fail_connect(msg)
    }
    return ok_connect(fd, timeout_ms)
}

public def connect_unix(path: str) -> TcpConnect {
    return connect_unix_timeout(path, 10000)
}

public def listen_unix(path: str) -> TcpListen {
    if path.len() == 0 {
        return fail_listen("socket path is empty")
    }
    if path.len() > 107 {
        return fail_listen("socket path too long")
    }
    fd = socket(1, 1, 0)   # AF_UNIX / SOCK_STREAM
    if fd < 0 {
        return fail_listen(error_text(errno_code()))
    }
    sa = unix_sockaddr(path)
    slen = unix_sockaddr_len(path)
    opt = buf_alloc(4)
    buf_set32(opt, 0, 0)
    setsockopt(fd, 1, 2, opt, 4)   # SO_REUSEADDR
    buf_free(opt)
    rc = tcp_bind_fd(fd, sa, slen)
    e = errno_code()
    if rc != 0 and e == 98 {   # EADDRINUSE: clean up the leftover socket file and retry
        if not is_abstract_path(path) and is_socket_file(path) {
            unlink(path)
            rc = tcp_bind_fd(fd, sa, slen)
            e = errno_code()
        }
    }
    buf_free(sa)
    if rc != 0 {
        close(fd)
        msg = "bind failed"
        if e != 0 {
            msg = error_text(e)
        }
        return fail_listen(msg)
    }
    lrc = tcp_listen_fd(fd, 128)
    if lrc != 0 {
        e2 = errno_code()
        close(fd)
        msg = "listen failed"
        if e2 != 0 {
            msg = error_text(e2)
        }
        return fail_listen(msg)
    }
    return ok_listen(fd, path)
}
