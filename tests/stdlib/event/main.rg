import asyncio
import event
import net
import time
import udp
from event import EventLoop

async def delayed_post(wake_fd: int) -> int {
    time.sleep(0.03)
    event.post_fd(wake_fd, 123)
    return 1
}

async def wait_post(l: EventLoop) -> int {
    t = delayed_post(l.wake_w)
    w = l.wait(1000)
    n = w.events.len()
    tok = -1
    if n > 0 {
        tok = w.events.get(0).token
    }
    v = await t
    ok = n == 1 and tok == 123 and v == 1
    l.close()
    wend = l.wait(0)
    if not ok {
        return 2
    }
    if wend.ok or wend.error.len() == 0 {
        return 3
    }
    return 1
}

def main() -> int {
    loop = event.new_loop()
    print("open", loop.is_open(), loop.error.len())
    print("timer_count0", loop.timer_count())

    w0 = loop.wait(20)
    print("wait_timeout", w0.ok, w0.timeout, w0.events.len())

    t = loop.add_timer(7, 5)
    print("add_timer", t.ok, t.error.len(), loop.timer_count())
    w1 = loop.wait(-1)
    e1 = w1.events.get(0)
    print("timer_event", w1.ok, w1.timeout, w1.events.len(), e1.token,
          e1.events == event.ev_timeout())
    print("timer_count1", loop.timer_count())

    loop.add_timer(1, 2)
    loop.add_timer(2, 20)
    wa = loop.wait(-1)
    print("timer_order1", wa.events.len(), wa.events.get(0).token)
    wb = loop.wait(-1)
    print("timer_order2", wb.events.len(), wb.events.get(0).token)

    loop.add_timer(9, 5000)
    print("timer_cancel", loop.cancel_timer(9), loop.timer_count())
    wc = loop.wait(10)
    print("cancel_wait", wc.timeout, wc.events.len())

    loop.add_interval(3, 2)
    wi1 = loop.wait(-1)
    wi2 = loop.wait(-1)
    print("interval", wi1.events.get(0).token, wi2.events.get(0).token)
    print("interval_cancel", loop.cancel_timer(3), loop.timer_count())

    print("post1", loop.post(41))
    print("post2", loop.post(42))
    wp = loop.wait(100)
    print("post_events", wp.ok, wp.events.len(), wp.events.get(0).token,
          wp.events.get(1).token, wp.events.get(0).events == event.ev_wake())

    bad = loop.add(-1, 0, event.ev_in())
    print("bad_fd", bad.ok, bad.error)
    print("bad_token", loop.post(-1))
    print("bad_timer", loop.add_timer(-2, 1).ok)

    ls = net.listen_on("127.0.0.1", 0)
    print("listen", ls.ok)
    lis = ls.listener
    lis.set_nonblocking(True)
    port = lis.local_port()
    cs = net.connect_start_to("127.0.0.1", port)
    print("client_start", cs.ok)
    cli = cs.stream
    if cs.pending {
        print("reg_client", loop.add(cli.fd, 11, event.ev_out()).ok)
        wc1 = loop.wait(1000)
        print("connect_ready", wc1.events.len() == 1,
              wc1.events.get(0).token == 11)
    } else {
        print("reg_client", True)
        print("connect_ready", True, True)
    }
    cf = net.connect_finish(cli)
    print("connect_finish", cf.ok)
    cli = cf.stream
    loop.remove(cli.fd)

    ra = loop.add(lis.fd, 10, event.ev_in())
    print("reg_listen", ra.ok, ra.error.len())
    wl = loop.wait(1000)
    print("listen_ready", wl.events.len() == 1, wl.events.get(0).token == 10)
    a = lis.try_accept()
    print("accept", a.ok, a.again)
    srv = a.stream
    srv.set_nonblocking(True)

    print("reg_server", loop.add(srv.fd, 20, event.ev_in()).ok)
    sn = cli.try_send("ping")
    print("client_send", sn.ok, sn.again, sn.sent)
    wr = loop.wait(1000)
    print("server_ready", wr.events.len(), wr.events.get(0).token)
    rr = srv.try_recv(16)
    print("server_recv", rr.ok, rr.again, rr.value)
    print("server_recv_again", srv.try_recv(16).again)

    print("reg_client_read", loop.add(cli.fd, 21, event.ev_in()).ok)
    print("modify_client",
          loop.modify(cli.fd, 22, event.ev_in() | event.ev_rdhup()).ok)
    sn2 = srv.try_send("pong")
    print("server_send", sn2.ok, sn2.sent)
    wb2 = loop.wait(1000)
    print("client_ready", wb2.events.len(), wb2.events.get(0).token)
    rb = cli.try_recv(16)
    print("client_recv", rb.ok, rb.value)

    srv.close()
    we = loop.wait(1000)
    print("close_ready", we.events.len(), we.events.get(0).token)
    re = cli.try_recv(16)
    print("client_eof", re.ok, re.again, re.value.len())

    print("remove_client", loop.remove(cli.fd).ok)
    print("remove_listen", loop.remove(lis.fd).ok)
    print("remove_again", loop.remove(lis.fd).ok)
    cli.close()
    lis.close()
    print("final_wait", loop.wait(20).timeout)

    u1 = udp.open("127.0.0.1:0")
    u2 = udp.open("127.0.0.1:0")
    print("udp_open", u1.ok, u2.ok)
    s1 = u1.sock
    s2 = u2.sock
    s1.set_nonblocking(True)
    print("udp_empty", s1.try_recv_from(16).again)
    print("udp_reg", loop.add(s1.fd, 30, event.ev_in()).ok)
    sr = s2.try_send_to("dgram", "127.0.0.1", s1.local_port())
    print("udp_send", sr.ok, sr.again, sr.sent)
    wu = loop.wait(1000)
    print("udp_event", wu.events.len(), wu.events.get(0).token == 30)
    ru = s1.try_recv_from(16)
    print("udp_recv", ru.ok, ru.again, ru.data, ru.host.len() > 0, ru.port > 0)
    print("udp_empty2", s1.try_recv_from(16).again)
    loop.remove(s1.fd)
    s1.close()
    s2.close()

    loop.close()
    print("closed", loop.is_open())
    wend = loop.wait(0)
    print("wait_closed", wend.ok, wend.error)

    l2 = event.new_loop()
    print("post_thread", asyncio.run(wait_post(l2)))
    return 0
}
