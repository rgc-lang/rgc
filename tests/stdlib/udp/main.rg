# udp: loopback send/receive, datagram boundaries, IPv6, binary, timeout, error paths
import bytes
import udp

def main() -> int {
    b1 = udp.open("127.0.0.1:0")
    print("bind1", b1.ok)
    if not b1.ok {
        print("bind1_error", b1.error)
        return 1
    }
    b2 = udp.open("127.0.0.1:0")
    print("bind2", b2.ok)
    if not b2.ok {
        print("bind2_error", b2.error)
        return 1
    }
    p1 = b1.sock.local_port()
    p2 = b2.sock.local_port()
    print("ports", p1 > 0, p2 > 0, p1 != p2)

    sr = b1.sock.send_to("ping", "127.0.0.1", p2)
    print("send", sr.ok, sr.sent)
    rr = b2.sock.recv_from(64)
    print("recv", rr.ok, rr.data, rr.host, rr.port == p1)

    # Datagram boundaries are preserved: two sends correspond to two receives.
    b1.sock.send_to("one", "127.0.0.1", p2)
    b1.sock.send_to("two", "127.0.0.1", p2)
    r1 = b2.sock.recv_from(64)
    r2 = b2.sock.recv_from(64)
    print("dgram", r1.data, r2.data)

    # Empty datagram: recvfrom returns 0, ok=True.
    b1.sock.send_to("", "127.0.0.1", p2)
    r3 = b2.sock.recv_from(64)
    print("empty", r3.ok, r3.data.len())

    # Over-long datagrams are truncated at max.
    b1.sock.send_to("abcdef", "127.0.0.1", p2)
    r4 = b2.sock.recv_from(3)
    print("trunc", r4.ok, r4.data)

    # Hostname resolution (localhost should resolve to loopback).
    b1.sock.send_to("hostname", "localhost", p2)
    r5 = b2.sock.recv_from(64)
    print("hostname", r5.ok, r5.data)

    # IPv6 loopback (separate socket).
    v6 = udp.open_on("::1", 0)
    print("ipv6_bind", v6.ok)
    if v6.ok {
        v6.sock.send_to("v6", "::1", v6.sock.local_port())
        r6 = v6.sock.recv_from(16)
        print("ipv6", r6.ok, r6.data, r6.host, r6.port == v6.sock.local_port())
        v6.sock.close()
    }

    # Binary payload: data is truncated per C-string semantics; data_bytes keeps every byte.
    bin = bytes.bytes_new(3)
    bin.push(0)
    bin.push(1)
    bin.push(255)
    b1.sock.send_bytes(bin, "127.0.0.1", p2)
    r7 = b2.sock.recv_from(16)
    print("binary", r7.ok, r7.data_bytes.len, r7.data_bytes.get(0),
          r7.data_bytes.get(2))

    # Non-blocking send/receive: again=True when there is no datagram.
    b2.sock.set_nonblocking(True)
    n0 = b2.sock.try_recv_from(16)
    print("try_empty", n0.ok, n0.again)
    ns = b1.sock.try_send_to("nb", "127.0.0.1", p2)
    print("try_send", ns.ok, ns.again, ns.sent)
    got = ""
    i = 0
    while i < 1000 and got.len() == 0 {
        nr = b2.sock.try_recv_from(16)
        if nr.ok and not nr.again {
            got = nr.data
        }
        i = i + 1
    }
    print("try_recv", got)
    b2.sock.set_nonblocking(False)

    # Read timeout.
    b2.sock.set_timeout(100)
    r8 = b2.sock.recv_from(16)
    print("timeout", r8.ok, r8.error)
    b2.sock.set_timeout(0)

    # Error paths.
    e1 = udp.open("nohost")
    print("badaddr", e1.ok, e1.error)
    e2 = udp.open("host:99999")
    print("badport", e2.ok, e2.error)
    e3 = b1.sock.send_to("x", "", 80)
    print("emptyhost", e3.ok, e3.error)
    e4 = b1.sock.send_to("x", "127.0.0.1", 70000)
    print("rangeport", e4.ok, e4.error)
    e5 = b2.sock.recv_from(0)
    print("zeromax", e5.ok, e5.error)
    e6 = b1.sock.send_to("x", "no.such.host.invalid", 80)
    print("resolve", e6.ok, e6.error.len() > 0)

    # Sending/receiving after close is forbidden.
    b1.sock.close()
    e7 = b1.sock.send_to("x", "127.0.0.1", p2)
    print("closed_send", e7.ok, e7.error)
    e8 = b1.sock.recv_from(8)
    print("closed_recv", e8.ok, e8.error)
    print("closed_port", b1.sock.local_port())

    b2.sock.close()
    return 0
}
