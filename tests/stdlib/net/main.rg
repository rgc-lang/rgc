import net

def main() -> int {
    l = net.listen_on("127.0.0.1", 0)
    print("listen", l.ok)
    if not l.ok {
        print("listen_err", l.error)
        return 1
    }
    listener = l.listener
    port = listener.local_port()
    print("port_positive", port > 0)

    c = net.connect("127.0.0.1:" + to_string(port))
    print("connect", c.ok)
    if not c.ok {
        print("connect_err", c.error)
        return 1
    }
    client = c.stream

    a = listener.accept()
    print("accept", a.ok)
    if not a.ok {
        print("accept_err", a.error)
        return 1
    }
    server = a.stream

    print("client_send", client.send("hello"))
    r1 = server.recv(16)
    print("server_recv", r1.ok, r1.value)

    print("server_send", server.send("world"))
    r2 = client.recv(16)
    print("client_recv", r2.ok, r2.value)

    z = client.recv(0)
    print("recv_zero", z.ok, "[" + z.value + "]")

    client.close()
    eof = server.recv(16)
    print("eof", eof.ok, eof.value.len())
    server.close()

    c2 = net.connect_to("localhost", port)
    print("hostname_connect", c2.ok)
    a2 = listener.accept()
    print("second_accept", a2.ok)
    if c2.ok {
        c2.stream.close()
    }
    if a2.ok {
        a2.stream.close()
    }
    listener.close()

    bad = net.connect("127.0.0.1")
    print("bad_addr", bad.ok, bad.error)
    bad_port = net.connect("127.0.0.1:99999")
    print("bad_port", bad_port.ok, bad_port.error)
    empty = net.listen_on("", 0)
    print("empty_host", empty.ok, empty.error)

    refused = net.connect_to("127.0.0.1", 1)
    print("refused", refused.ok, refused.error.len() > 0)

    l3 = net.listen_on("127.0.0.1", 0)
    lis3 = l3.listener
    lis3.set_nonblocking(True)
    print("try_accept_again", lis3.try_accept().again)
    cs = net.connect_start_to("127.0.0.1", lis3.local_port())
    print("connect_start", cs.ok)
    raw = cs.stream
    if cs.pending {
        print("connect_poll", net.wait_fd(raw.fd, 4, 1000) > 0)
    } else {
        print("connect_poll", True)
    }
    cf = net.connect_finish(raw)
    print("connect_finish", cf.ok)
    nc = cf.stream
    print("client_again", nc.try_recv(8).again)
    a3 = lis3.try_accept()
    print("try_accept", a3.ok, a3.again)
    ns = a3.stream
    ns.set_nonblocking(True)
    ts = nc.try_send("abc")
    print("try_send", ts.ok, ts.again, ts.sent)
    print("read_ready", net.wait_fd(ns.fd, 1, 1000) > 0)
    print("try_recv", ns.try_recv(8).value)
    ts2 = ns.try_send("xyz")
    print("try_send2", ts2.ok, ts2.again, ts2.sent)
    print("read_ready2", net.wait_fd(nc.fd, 1, 1000) > 0)
    print("try_recv2", nc.try_recv(8).value)
    nc.close()
    print("server_eof", ns.try_recv(8).ok, ns.try_recv(8).value.len() == 0)
    ns.close()
    lis3.close()
    return 0
}
