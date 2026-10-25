# RGC standard library: udp
#
# Synchronous UDP (IPv4 / IPv6 / hostnames), calling libc socket directly via extern defs underneath.
# The language does not yet support Result[custom types]; bind/send/receive results are carried by classes with ok/error fields.
#
# Usage:
#   import udp
#   b = udp.open("127.0.0.1:0")
#   if b.ok {
#       s = b.sock
#       s.send_to("ping", "127.0.0.1", s.local_port())
#       r = s.recv_from(1024)
#       if r.ok { print(r.data, r.host, r.port) }
#       s.close()
#   }
#
# Semantics:
#   - send_to / recv_from block; recv_from reads at most max bytes.
#   - Datagram boundaries are preserved: one recv_from corresponds to one datagram (bytes beyond max are dropped).
#   - Address format is "host:port"; IPv6 literals are written as "[::1]:8080" or "::1".
#   - Binary payloads use send_bytes / the data_bytes (Bytes) returned by recv_from.
#   - set_timeout(ms) sets send/receive timeouts (SO_RCVTIMEO/SO_SNDTIMEO); 0 means blocking.
#   - Temporary buffers for receive/send are freed per call; the returned data/data_bytes are heap-allocated (currently no GC).

import bytes
import net

extern def socket(domain: int, kind: int, protocol: int) -> int
extern def bind(fd: int, addr: str, addrlen: int) -> int
extern def sendto(fd: int, buf: str, size: int, flags: int, addr: str, addrlen: int) -> int
extern def recvfrom(fd: int, buf: str, size: int, flags: int, addr: str, addrlen: str) -> int
extern def getsockname(fd: int, addr: str, addrlen: str) -> int
extern def close(fd: int) -> int

public class UdpSend {
    ok: bool
    again: bool
    error: str
    sent: int
}

public class UdpRecv {
    ok: bool
    again: bool
    error: str
    data: str
    data_bytes: Bytes
    host: str
    port: int
}

public class UdpSocket {
    fd: int
    family: int

    def send_to(self, data: str, host: str, port: int) -> UdpSend {
        return self.send_mem(data, data.len(), host, port)
    }

    def send_bytes(self, data: @Bytes, host: str, port: int) -> UdpSend {
        return self.send_mem(data.data, data.len, host, port)
    }

    def send_mem(self, p: str, n: int, host: str, port: int) -> UdpSend {
        r = UdpSend()
        r.ok = False
        r.again = False
        r.error = ""
        r.sent = 0
        if self.fd < 0 {
            r.error = "socket is closed"
            return r
        }
        if host.len() == 0 {
            r.error = "host is empty"
            return r
        }
        if port < 0 or port > 65535 {
            r.error = "port out of range"
            return r
        }
        addrs = net.resolve_sockaddrs(strip_brackets(host), port, 2, False)
        if addrs.len() == 0 {
            r.error = "cannot resolve host"
            return r
        }
        sa = ""
        salen = 0
        i = 0
        while i < addrs.len() {
            a = addrs.get(i)
            if a.family == self.family {
                sa = a.sa
                salen = a.len
                i = addrs.len()
            } else {
                i = i + 1
            }
        }
        if salen == 0 {
            net.free_sockaddrs(@addrs)
            r.error = "address family not supported"
            return r
        }
        sent = sendto(self.fd, p, n, 0, sa, salen)
        net.free_sockaddrs(@addrs)
        if sent < 0 {
            e = last_error()
            if e.len() == 0 {
                e = "send failed"
            }
            r.error = e
            pass
        } else {
            r.ok = True
            r.sent = sent
            pass
        }
        return r
    }

    def recv_from(self, max: int) -> UdpRecv {
        r = UdpRecv()
        r.ok = False
        r.again = False
        r.error = ""
        r.data = ""
        r.data_bytes = bytes.bytes_new(0)
        r.host = ""
        r.port = 0
        if self.fd < 0 {
            r.error = "socket is closed"
            return r
        }
        if max <= 0 {
            r.error = "max must be positive"
            return r
        }
        buf = buf_alloc(max)
        sa = buf_alloc(128)
        lenp = buf_alloc(4)
        buf_zero(sa, 128)
        buf_set32(lenp, 0, 128)
        n = recvfrom(self.fd, buf, max, 0, sa, lenp)
        if n < 0 {
            e = last_error()
            if e.len() == 0 {
                e = "recv failed"
            }
            r.error = e
        } else {
            r.ok = True
            r.data = buf_to_str(buf, n)
            r.data_bytes = bytes.bytes_from_mem(buf, n)
            r.host = net.sockaddr_host(sa, buf_get32(lenp, 0))
            r.port = net.sockaddr_port(sa)
            pass
        }
        buf_free(buf)
        buf_free(sa)
        buf_free(lenp)
        return r
    }

    def set_timeout(self, ms: int) {
        net.set_socket_timeout(self.fd, 20, ms)   # SO_RCVTIMEO
        net.set_socket_timeout(self.fd, 21, ms)   # SO_SNDTIMEO
    }

    def set_nonblocking(self, on: bool) {
        net.set_nonblocking(self.fd, on)
    }

    # Non-blocking receive: ok=True, again=True when there is no datagram.
    def try_recv_from(self, max: int) -> UdpRecv {
        r = UdpRecv()
        r.ok = False
        r.again = False
        r.error = ""
        r.data = ""
        r.data_bytes = bytes.bytes_new(0)
        r.host = ""
        r.port = 0
        if self.fd < 0 {
            r.error = "socket is closed"
            return r
        }
        if max <= 0 {
            r.error = "max must be positive"
            return r
        }
        buf = buf_alloc(max)
        sa = buf_alloc(128)
        lenp = buf_alloc(4)
        buf_zero(sa, 128)
        buf_set32(lenp, 0, 128)
        n = -1
        ecode = 0
        while True {
            n = recvfrom(self.fd, buf, max, 0, sa, lenp)
            if n >= 0 {
                break
            }
            ecode = net.errno_code()
            if ecode == 4 {   # EINTR
                continue
            }
            break
        }
        if n < 0 {
            if ecode == 11 {   # EAGAIN / EWOULDBLOCK
                r.ok = True
                r.again = True
            } else {
                e = net.error_text(ecode)
                if e.len() == 0 {
                    e = "recv failed"
                }
                r.error = e
            }
        } else {
            r.ok = True
            r.data = buf_to_str(buf, n)
            r.data_bytes = bytes.bytes_from_mem(buf, n)
            r.host = net.sockaddr_host(sa, buf_get32(lenp, 0))
            r.port = net.sockaddr_port(sa)
        }
        buf_free(buf)
        buf_free(sa)
        buf_free(lenp)
        return r
    }

    def try_send_to(self, data: str, host: str, port: int) -> UdpSend {
        return self.try_send_mem(data, data.len(), host, port)
    }

    def try_send_bytes(self, data: @Bytes, host: str, port: int) -> UdpSend {
        return self.try_send_mem(data.data, data.len, host, port)
    }

    # Non-blocking send: ok=True, again=True when the kernel buffer is full.
    def try_send_mem(self, p: str, n: int, host: str, port: int) -> UdpSend {
        r = UdpSend()
        r.ok = False
        r.again = False
        r.error = ""
        r.sent = 0
        if self.fd < 0 {
            r.error = "socket is closed"
            return r
        }
        if host.len() == 0 {
            r.error = "host is empty"
            return r
        }
        if port < 0 or port > 65535 {
            r.error = "port out of range"
            return r
        }
        addrs = net.resolve_sockaddrs(strip_brackets(host), port, 2, False)
        if addrs.len() == 0 {
            r.error = "cannot resolve host"
            return r
        }
        sa = ""
        salen = 0
        i = 0
        while i < addrs.len() {
            a = addrs.get(i)
            if a.family == self.family {
                sa = a.sa
                salen = a.len
                i = addrs.len()
            } else {
                i = i + 1
            }
        }
        if salen == 0 {
            net.free_sockaddrs(@addrs)
            r.error = "address family not supported"
            return r
        }
        sent = sendto(self.fd, p, n, 0, sa, salen)
        if sent < 0 {
            ecode = net.errno_code()
            if ecode == 11 {   # EAGAIN / EWOULDBLOCK
                r.ok = True
                r.again = True
            } else {
                e = net.error_text(ecode)
                if e.len() == 0 {
                    e = "send failed"
                }
                r.error = e
            }
        } else {
            r.ok = True
            r.sent = sent
        }
        net.free_sockaddrs(@addrs)
        return r
    }

    def local_port(self) -> int {
        if self.fd < 0 {
            return -1
        }
        sa = buf_alloc(128)
        lenp = buf_alloc(4)
        buf_zero(sa, 128)
        buf_set32(lenp, 0, 128)
        rc = getsockname(self.fd, sa, lenp)
        p = -1
        if rc == 0 {
            p = net.sockaddr_port(sa)
        }
        buf_free(sa)
        buf_free(lenp)
        return p
    }

    def close(self) {
        if self.fd >= 0 {
            close_fd(self.fd)
            self.fd = -1
        }
    }
}

def close_fd(fd: int) {
    close(fd)
}

def last_error() -> str {
    return net.error_text(net.errno_code())
}

public class UdpBind {
    ok: bool
    error: str
    sock: UdpSocket
}

class AddrParts {
    ok: bool
    error: str
    host: str
    port: int
}

def strip_brackets(host: str) -> str {
    if host.len() > 2 {
        if host.char_at(0) == 91 and host.char_at(host.len() - 1) == 93 {
            return host.slice(1, host.len() - 1)
        }
    }
    return host
}

def parse_addr(addr: str) -> AddrParts {
    r = AddrParts()
    r.ok = False
    r.error = ""
    r.host = ""
    r.port = 0
    i = addr.len() - 1
    while i >= 0 {
        if addr.char_at(i) == 58 {   # ':'
            host = addr.slice(0, i)
            port_text = addr.slice(i + 1, addr.len())
            if host.len() == 0 or port_text.len() == 0 {
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
            r.host = strip_brackets(host)
            r.port = p
            r.ok = True
            return r
        }
        i = i - 1
    }
    r.error = "address must be host:port"
    return r
}

def empty_sock() -> UdpSocket {
    s = UdpSocket()
    s.fd = -1
    s.family = 2
    return s
}

def fail_bind(msg: str) -> UdpBind {
    r = UdpBind()
    r.ok = False
    r.error = msg
    r.sock = empty_sock()
    return r
}

public def open_on(host: str, port: int) -> UdpBind {
    if host.len() == 0 {
        return fail_bind("host is empty")
    }
    if port < 0 or port > 65535 {
        return fail_bind("port out of range")
    }
    addrs = net.resolve_sockaddrs(strip_brackets(host), port, 2, True)
    if addrs.len() == 0 {
        return fail_bind("cannot resolve host")
    }
    a = addrs.get(0)
    family = a.family
    fd = socket(family, 2, 0)   # SOCK_DGRAM
    if fd < 0 {
        e = last_error()
        if e.len() == 0 {
            e = "socket failed"
        }
        net.free_sockaddrs(@addrs)
        return fail_bind(e)
    }
    rc = bind(fd, a.sa, a.len)
    if rc != 0 {
        e = last_error()
        if e.len() == 0 {
            e = "bind failed"
        }
        net.free_sockaddrs(@addrs)
        close_fd(fd)
        return fail_bind(e)
    }
    net.free_sockaddrs(@addrs)
    r = UdpBind()
    r.ok = True
    r.error = ""
    s = UdpSocket()
    s.fd = fd
    s.family = family
    r.sock = s
    return r
}

public def open(addr: str) -> UdpBind {
    p = parse_addr(addr)
    if not p.ok {
        return fail_bind(p.error)
    }
    return open_on(p.host, p.port)
}
