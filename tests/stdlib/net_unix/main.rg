import net
import time

def main() -> int {
    path = "/tmp/rgc_net_unix_" + to_string(time.monotonic_ms()) + ".sock"

    l = net.listen_unix(path)
    print("listen", l.ok)
    if not l.ok {
        print("listen_err", l.error)
        return 1
    }
    listener = l.listener

    c = net.connect_unix(path)
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

    print("client_send", client.send("unix hello"))
    r1 = server.recv(32)
    print("server_recv", r1.ok, r1.value)
    print("server_send", server.send("unix world"))
    r2 = client.recv(32)
    print("client_recv", r2.ok, r2.value)

    client.close()
    eof = server.recv(32)
    print("eof", eof.ok, eof.value.len())
    server.close()
    listener.close()

    missing = net.connect_unix(path)
    print("missing", missing.ok, missing.error.len() > 0)

    empty = net.listen_unix("")
    print("empty_path", empty.ok, empty.error)
    long_path = "/tmp/"
    i = 0
    while i < 120 {
        long_path = long_path + "x"
        i = i + 1
    }
    long_l = net.listen_unix(long_path)
    print("long_path", long_l.ok, long_l.error)
    long_c = net.connect_unix(long_path)
    print("long_connect", long_c.ok, long_c.error)

    # A crashed process leaves the socket file behind: close the fd directly, then
    # listen_unix must recognize the stale socket file and replace it.
    l2 = net.listen_unix(path)
    if l2.ok {
        net.close_fd(l2.listener.fd)
        l2.listener.fd = -1
    }
    l3 = net.listen_unix(path)
    print("stale_cleanup", l3.ok)
    if l3.ok {
        l3.listener.close()
    }
    return 0
}
