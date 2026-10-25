# RGC standard library: event
#
# Linux epoll event loop (single-threaded selector): registers fds and timeout timers,
# then blocks waiting for ready events. Combined with net/udp non-blocking primitives, it enables event-driven IO.
# It does not depend on compiler closures or function pointers; all low-level calls go through extern def + libc.
#
# Usage:
#   import event
#   import net
#   loop = event.new_loop()
#   l = net.listen_on("127.0.0.1", 8080)
#   loop.add(l.listener.fd, 10, event.ev_in())
#   while True {
#       w = loop.wait(-1)
#       i = 0
#       while i < w.events.len() {
#           e = w.events.get(i)
#           if e.token == 10 {
#               a = l.listener.try_accept()
#               ...
#           }
#           i = i + 1
#       }
#   }
#
# Semantics:
#   - add/modify/remove manage fd registrations; the token is assigned by the caller to identify events,
#     and should be unique within a loop (0 <= token < 2^62).
#   - wait(timeout_ms) waits for fd or timer events; timeout_ms < 0 means wait indefinitely,
#     0 means poll once. Returns EventWait; timeout=True when events is empty and there is no error.
#   - Timers are based on timerfd (CLOCK_MONOTONIC): add_timer fires once, add_interval fires periodically;
#     expired events include ev_timeout() in events. cancel_timer cancels.
#   - post(token) can be called from other threads; it wakes wait and delivers an ev_wake() event.
#   - Event bits: ev_in/ev_out/ev_err/ev_hup/ev_rdhup match epoll; ev_edge() can be added.
#   - A loop should only be waited on by one thread; add/remove/timer management should also run on that thread;
#     only post is allowed to be called concurrently from other threads.
#   - close closes the epoll fd, the wake pipe, and all timer fds; wait returns an error after close.

extern def epoll_create1(flags: int) -> int
extern def epoll_ctl(epfd: int, op: int, fd: int, ev: str) -> int
extern def epoll_wait(epfd: int, evs: str, maxevents: int, timeout: int) -> int
extern def socketpair(domain: int, kind: int, protocol: int, fds: str) -> int
extern def timerfd_create(clockid: int, flags: int) -> int
extern def timerfd_settime(fd: int, flags: int, new_value: str, old_value: str) -> int
extern def read(fd: int, buf: str, count: int) -> int
extern def send(fd: int, buf: str, len: int, flags: int) -> int
extern def fcntl(fd: int, cmd: int, arg: int) -> int
extern def close(fd: int) -> int
extern def __errno_location() -> str
extern def strerror(code: int) -> str

class TimerWatch {
    token: int
    fd: int
    interval_ms: int
}

public class Event {
    token: int
    events: int
}

public class EventOp {
    ok: bool
    error: str
}

public class EventWait {
    ok: bool
    error: str
    timeout: bool
    events: List[Event]
}

public class EventLoop {
    epfd: int
    wake_r: int
    wake_w: int
    timers: List[TimerWatch]
    error: str

    def is_open(self) -> bool {
        return self.epfd >= 0
    }

    # events is a bitwise combination like ev_in()/ev_out(); token identifies the fd's events.
    def add(self, fd: int, token: int, events: int) -> EventOp {
        r = init_op()
        if self.epfd < 0 {
            r.error = "event loop is closed"
            return r
        }
        if fd < 0 {
            r.error = "invalid fd"
            return r
        }
        if not token_ok(token) {
            r.error = "token out of range"
            return r
        }
        ev = make_ctl_event(events, token)
        rc = epoll_ctl(self.epfd, 1, fd, ev)   # EPOLL_CTL_ADD
        e = errno_code()
        buf_free(ev)
        if rc < 0 {
            r.error = error_text(e)
            return r
        }
        r.ok = True
        return r
    }

    def modify(self, fd: int, token: int, events: int) -> EventOp {
        r = init_op()
        if self.epfd < 0 {
            r.error = "event loop is closed"
            return r
        }
        if fd < 0 {
            r.error = "invalid fd"
            return r
        }
        if not token_ok(token) {
            r.error = "token out of range"
            return r
        }
        ev = make_ctl_event(events, token)
        rc = epoll_ctl(self.epfd, 3, fd, ev)   # EPOLL_CTL_MOD
        e = errno_code()
        buf_free(ev)
        if rc < 0 {
            r.error = error_text(e)
            return r
        }
        r.ok = True
        return r
    }

    def remove(self, fd: int) -> EventOp {
        r = init_op()
        if self.epfd < 0 {
            r.error = "event loop is closed"
            return r
        }
        if fd < 0 {
            r.error = "invalid fd"
            return r
        }
        ev = make_ctl_event(0, 0)
        rc = epoll_ctl(self.epfd, 2, fd, ev)   # EPOLL_CTL_DEL
        e = errno_code()
        buf_free(ev)
        if rc < 0 {
            r.error = error_text(e)
            return r
        }
        r.ok = True
        return r
    }

    # One-shot timer: delivers an ev_timeout() event for token after delay_ms.
    def add_timer(self, token: int, delay_ms: int) -> EventOp {
        return self.add_timer_at(token, delay_ms, 0)
    }

    # Periodic timer: fires after the first interval_ms, then once every period.
    def add_interval(self, token: int, interval_ms: int) -> EventOp {
        return self.add_timer_at(token, interval_ms, interval_ms)
    }

    def add_timer_at(self, token: int, delay_ms: int, interval_ms: int) -> EventOp {
        r = init_op()
        if self.epfd < 0 {
            r.error = "event loop is closed"
            return r
        }
        if not token_ok(token) {
            r.error = "token out of range"
            return r
        }
        if delay_ms < 0 {
            delay_ms = 0
        }
        if interval_ms < 0 {
            interval_ms = 0
        }
        self.drop_timer(token)
        tfd = timerfd_create(1, 526336)   # CLOCK_MONOTONIC | TFD_NONBLOCK | TFD_CLOEXEC
        if tfd < 0 {
            r.error = error_text(errno_code())
            return r
        }
        spec = buf_alloc(32)
        buf_zero(spec, 32)
        if interval_ms > 0 {
            buf_set64(spec, 0, interval_ms / 1000)
            buf_set64(spec, 8, interval_ms % 1000 * 1000000)
        }
        buf_set64(spec, 16, delay_ms / 1000)
        buf_set64(spec, 24, delay_ms % 1000 * 1000000)
        rc = timerfd_settime(tfd, 0, spec, ptr_null())
        e = errno_code()
        buf_free(spec)
        if rc < 0 {
            close(tfd)
            r.error = error_text(e)
            return r
        }
        ev = make_ctl_event(1, token | timer_flag())   # EPOLLIN
        rc2 = epoll_ctl(self.epfd, 1, tfd, ev)
        e2 = errno_code()
        buf_free(ev)
        if rc2 < 0 {
            close(tfd)
            r.error = error_text(e2)
            return r
        }
        t = TimerWatch()
        t.token = token
        t.fd = tfd
        t.interval_ms = interval_ms
        self.timers.push(t)
        r.ok = True
        return r
    }

    def cancel_timer(self, token: int) -> bool {
        return self.drop_timer(token)
    }

    def timer_count(self) -> int {
        return self.timers.len()
    }

    def drop_timer(self, token: int) -> bool {
        i = self.timers.len() - 1
        while i >= 0 {
            t = self.timers.get(i)
            if t.token == token {
                close(t.fd)
                last = self.timers.len() - 1
                if i != last {
                    self.timers.set(i, self.timers.get(last))
                }
                self.timers.pop()
                return True
            }
            i = i - 1
        }
        return False
    }

    # Wake a wait() in progress; callable across threads. token must be non-negative and < 2^62.
    def post(self, token: int) -> bool {
        return post_fd(self.wake_w, token)
    }

    def wait(self, timeout_ms: int) -> EventWait {
        r = init_wait()
        if self.epfd < 0 {
            r.ok = False
            r.error = "event loop is closed"
            return r
        }
        ms = timeout_ms
        if ms < -1 {
            ms = -1
        }
        evs = buf_alloc(768)   # 64 * 12 bytes (packed struct epoll_event)
        n = 0
        while True {
            n = epoll_wait(self.epfd, evs, 64, ms)
            if n < 0 and errno_code() == 4 {   # EINTR
                continue
            }
            break
        }
        if n < 0 {
            e = errno_code()
            buf_free(evs)
            r.ok = False
            r.error = error_text(e)
            return r
        }
        i = 0
        while i < n {
            off = i * 12
            bits = buf_get32(evs, off)
            tok = buf_get64(evs, off + 4)
            if tok == wake_token() {
                # The wake pipe is always drained in drain_wake, so multiple posts can be coalesced.
            } elif (tok & timer_flag()) != 0 {
                ttoken = tok & timer_mask()
                r.events.push(make_event(ev_timeout_value(), ttoken))
                self.consume_timer(ttoken)
            } else {
                r.events.push(make_event(bits, tok))
            }
            i = i + 1
        }
        buf_free(evs)
        pending = r.events
        self.drain_wake(pending)
        r.events = pending
        if n == 0 and r.events.len() == 0 {
            r.timeout = True
        }
        return r
    }

    def drain_wake(self, out: @var List[Event]) {
        b = buf_alloc(8)
        while True {
            n = read(self.wake_r, b, 8)
            if n != 8 {
                break
            }
            out.push(make_event(ev_wake_value(), buf_get64(b, 0)))
        }
        buf_free(b)
    }

    def consume_timer(self, token: int) {
        i = self.timers.len() - 1
        while i >= 0 {
            t = self.timers.get(i)
            if t.token == token {
                b = buf_alloc(8)
                read(t.fd, b, 8)   # clear the expiration count
                buf_free(b)
                if t.interval_ms <= 0 {
                    close(t.fd)
                    last = self.timers.len() - 1
                    if i != last {
                        self.timers.set(i, self.timers.get(last))
                    }
                    self.timers.pop()
                }
                return
            }
            i = i - 1
        }
    }

    def close(self) {
        if self.epfd >= 0 {
            close(self.epfd)
            self.epfd = -1
        }
        if self.wake_r >= 0 {
            close(self.wake_r)
            self.wake_r = -1
        }
        if self.wake_w >= 0 {
            close(self.wake_w)
            self.wake_w = -1
        }
        i = 0
        while i < self.timers.len() {
            close(self.timers.get(i).fd)
            i = i + 1
        }
        self.timers.clear()
    }
}

def timer_flag() -> int {
    return 4611686018427387904   # 1 << 62
}

def timer_mask() -> int {
    return 4611686018427387903
}

def wake_token() -> int {
    return -1
}

def ev_timeout_value() -> int {
    return 256
}

def ev_wake_value() -> int {
    return 512
}

public def ev_in() -> int {
    return 1
}

public def ev_out() -> int {
    return 4
}

public def ev_err() -> int {
    return 8
}

public def ev_hup() -> int {
    return 16
}

public def ev_rdhup() -> int {
    return 8192
}

public def ev_edge() -> int {
    return 2147483648
}

public def ev_timeout() -> int {
    return ev_timeout_value()
}

public def ev_wake() -> int {
    return ev_wake_value()
}

def token_ok(token: int) -> bool {
    return token >= 0 and token <= timer_mask()
}

def make_event(events: int, token: int) -> Event {
    e = Event()
    e.token = token
    e.events = events
    return e
}

def make_ctl_event(events: int, token: int) -> str {
    b = buf_alloc(12)
    buf_zero(b, 12)
    buf_set32(b, 0, events)
    buf_set64(b, 4, token)
    return b
}

def init_op() -> EventOp {
    r = EventOp()
    r.ok = False
    r.error = ""
    return r
}

def init_wait() -> EventWait {
    r = EventWait()
    r.ok = True
    r.error = ""
    r.timeout = False
    r.events = List[Event]()
    return r
}

def errno_code() -> int {
    return buf_get32(__errno_location(), 0)
}

def error_text(code: int) -> str {
    if code == 0 {
        return "event loop error"
    }
    return strerror(code)
}

def set_nonblocking(fd: int, on: bool) {
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

public def new_loop() -> EventLoop {
    l = EventLoop()
    l.epfd = -1
    l.wake_r = -1
    l.wake_w = -1
    l.timers = List[TimerWatch]()
    l.error = ""
    ep = epoll_create1(0)
    if ep < 0 {
        l.error = error_text(errno_code())
        return l
    }
    fds = buf_alloc(8)
    buf_zero(fds, 8)
    rc = socketpair(1, 1, 0, fds)   # AF_UNIX / SOCK_STREAM
    if rc < 0 {
        l.error = error_text(errno_code())
        close(ep)
        buf_free(fds)
        return l
    }
    rfd = buf_get32(fds, 0)
    wfd = buf_get32(fds, 4)
    buf_free(fds)
    set_nonblocking(rfd, True)
    ev = make_ctl_event(1, wake_token())   # EPOLLIN
    rc2 = epoll_ctl(ep, 1, rfd, ev)
    e2 = errno_code()
    buf_free(ev)
    if rc2 < 0 {
        l.error = error_text(e2)
        close(ep)
        close(rfd)
        close(wfd)
        return l
    }
    l.epfd = ep
    l.wake_r = rfd
    l.wake_w = wfd
    return l
}

public def errno_value() -> int {
    return errno_code()
}

# One-shot epoll readiness wait without constructing an EventLoop.
# Returns 1 when ready, 0 on timeout, -1 on error. Intended for async wrappers that
# wait in short slices and poll asyncio.cancelled() between slices.
public def wait_fd(fd: int, events: int, timeout_ms: int) -> int {
    if fd < 0 {
        return -1
    }
    ep = epoll_create1(0)
    if ep < 0 {
        return -1
    }
    ev = make_ctl_event(events, 1)
    rc = epoll_ctl(ep, 1, fd, ev)
    buf_free(ev)
    if rc < 0 {
        close(ep)
        return -1
    }
    evs = buf_alloc(12)
    n = -1
    while True {
        n = epoll_wait(ep, evs, 1, timeout_ms)
        if n < 0 and errno_code() == 4 {   # EINTR
            continue
        }
        break
    }
    buf_free(evs)
    close(ep)
    return n
}

public def error_string(code: int) -> str {
    return error_text(code)
}

# Low-level wake: post a token to loop.wake_w (for direct use by other threads).
public def post_fd(wake_fd: int, token: int) -> bool {
    if wake_fd < 0 or not token_ok(token) {
        return False
    }
    b = buf_alloc(8)
    buf_set64(b, 0, token)
    n = send(wake_fd, b, 8, 0)
    buf_free(b)
    return n == 8
}
