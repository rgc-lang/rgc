# RGC standard library: event
#
# Cross-platform readiness loop built on poll(2) / WSAPoll: registers fds plus millisecond
# timers, then blocks waiting for ready events. Combined with net/udp non-blocking primitives
# it enables event-driven IO. All low-level calls go through extern def + libc/Winsock.
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
#   - Timers come from time.monotonic_ms() deadlines: add_timer fires once, add_interval fires
#     periodically; expired events include ev_timeout() in events. cancel_timer cancels.
#   - post(token) can be called from other threads; it wakes wait and delivers an ev_wake() event.
#     The wake channel is a connected UDP loopback socket pair, so message order is preserved.
#   - Event bits: ev_in/ev_out/ev_err/ev_hup/ev_rdhup match poll; ev_edge() is accepted but poll
#     has no edge-triggered mode, so registrations stay level-triggered on every platform.
#   - An fd closed without remove() is dropped silently the next time poll reports POLLNVAL,
#     matching epoll's automatic deregistration.
#   - A loop should only be waited on by one thread; add/remove/timer management should also run on that thread;
#     only post is allowed to be called concurrently from other threads.
#   - close closes the wake socket pair and drops all registrations; wait returns an error after close.

import time

extern def poll(fds: str, nfds: int, timeout: int) -> int
extern def socket(domain: int, kind: int, protocol: int) -> int
extern def bind(fd: int, addr: str, len: int) -> int
extern def connect(fd: int, addr: str, len: int) -> int
extern def getsockname(fd: int, addr: str, len: str) -> int
extern def recv(fd: int, buf: str, count: int, flags: int) -> int
extern def send(fd: int, buf: str, len: int, flags: int) -> int
extern def fcntl(fd: int, cmd: int, arg: int) -> int
extern def close(fd: int) -> int
extern def __errno_location() -> str
extern def strerror(code: int) -> str

class Watch {
    fd: int
    token: int
    events: int
    dead: bool
}

class TimerWatch {
    token: int
    fd: int
    interval_ms: int
    next_ms: int
}

class WakePair {
    ok: bool
    error: str
    r: int
    w: int
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
    epfd: int   # open marker: 1 while open, -1 after close
    wake_r: int
    wake_w: int
    timers: List[TimerWatch]
    watches: List[Watch]
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
        if self.find_watch(fd) >= 0 {
            r.error = error_text(17)   # EEXIST: poll has no duplicate registrations either
            return r
        }
        w = Watch()
        w.fd = fd
        w.token = token
        w.events = events
        w.dead = False
        self.watches.push(w)
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
        i = self.find_watch(fd)
        if i < 0 {
            r.error = error_text(2)   # ENOENT, matching epoll_ctl MOD on an unknown fd
            return r
        }
        w = self.watches.get(i)
        w.token = token
        w.events = events
        self.watches.set(i, w)   # List holds class values; writes must be stored back
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
        i = self.find_watch(fd)
        if i < 0 {
            r.error = error_text(2)
            return r
        }
        self.drop_watch_at(i)
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
        t = TimerWatch()
        t.token = token
        t.fd = -1
        t.interval_ms = interval_ms
        t.next_ms = time.monotonic_ms() + delay_ms
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
        now = time.monotonic_ms()
        deadline = -1
        if ms >= 0 {
            deadline = now + ms
        }
        next = self.next_timer_ms()
        if next >= 0 {
            d = next - now
            if d < 0 {
                d = 0
            }
            if deadline < 0 or d < deadline - now {
                deadline = now + d
            }
        }
        pms = -1
        if deadline >= 0 {
            pms = deadline - now
            if pms < 0 {
                pms = 0
            }
            if pms > 2147483647 {
                pms = 2147483647
            }
        }
        count = self.watches.len() + 1
        fds = buf_alloc(count * 8)
        buf_zero(fds, count * 8)
        set_pollfd(fds, 0, self.wake_r, 1)   # POLLIN
        i = 0
        while i < self.watches.len() {
            w = self.watches.get(i)
            set_pollfd(fds, (i + 1) * 8, w.fd, poll_events(w.events))
            i = i + 1
        }
        n = 0
        while True {
            n = poll(fds, count, pms)
            if n < 0 and errno_code() == 4 {   # EINTR
                continue
            }
            break
        }
        if n < 0 {
            e = errno_code()
            buf_free(fds)
            r.ok = False
            r.error = error_text(e)
            return r
        }
        if n > 0 {
            i = 0
            while i < self.watches.len() {
                w = self.watches.get(i)
                off = (i + 1) * 8 + 6
                rev = buf_get8(fds, off) + buf_get8(fds, off + 1) * 256
                if rev != 0 {
                    if (rev & 32) != 0 {   # POLLNVAL: the fd was closed, drop it like epoll does
                        w.dead = True
                        self.watches.set(i, w)
                    } else {
                        r.events.push(make_event(poll_bits(rev), w.token))
                    }
                }
                i = i + 1
            }
            self.reap_dead_watches()
        }
        self.collect_timers(r.events)
        buf_free(fds)
        pending = r.events
        self.drain_wake(pending)
        r.events = pending
        if n == 0 and r.events.len() == 0 {
            r.timeout = True
        }
        return r
    }

    def next_timer_ms(self) -> int {
        n = -1
        i = 0
        while i < self.timers.len() {
            t = self.timers.get(i)
            if n < 0 or t.next_ms < n {
                n = t.next_ms
            }
            i = i + 1
        }
        return n
    }

    def collect_timers(self, out: @var List[Event]) {
        now = time.monotonic_ms()
        i = 0
        while i < self.timers.len() {
            t = self.timers.get(i)
            if t.next_ms <= now {
                out.push(make_event(ev_timeout_value(), t.token))
                if t.interval_ms <= 0 {
                    last = self.timers.len() - 1
                    if i != last {
                        self.timers.set(i, self.timers.get(last))
                    }
                    self.timers.pop()
                } else {
                    next = t.next_ms + t.interval_ms
                    while next <= now {
                        next = next + t.interval_ms
                    }
                    t.next_ms = next
                    self.timers.set(i, t)
                    i = i + 1
                }
            } else {
                i = i + 1
            }
        }
    }

    def find_watch(self, fd: int) -> int {
        i = 0
        while i < self.watches.len() {
            if self.watches.get(i).fd == fd {
                return i
            }
            i = i + 1
        }
        return -1
    }

    def drop_watch_at(self, i: int) {
        last = self.watches.len() - 1
        if i != last {
            self.watches.set(i, self.watches.get(last))
        }
        self.watches.pop()
    }

    def reap_dead_watches(self) {
        i = self.watches.len() - 1
        while i >= 0 {
            if self.watches.get(i).dead {
                self.drop_watch_at(i)
            }
            i = i - 1
        }
    }

    def drain_wake(self, out: @var List[Event]) {
        b = buf_alloc(8)
        while True {
            n = recv(self.wake_r, b, 8, 0)
            if n != 8 {
                break
            }
            out.push(make_event(ev_wake_value(), buf_get64(b, 0)))
        }
        buf_free(b)
    }

    def close(self) {
        self.epfd = -1
        if self.wake_r >= 0 {
            close(self.wake_r)
            self.wake_r = -1
        }
        if self.wake_w >= 0 {
            close(self.wake_w)
            self.wake_w = -1
        }
        self.timers.clear()
        self.watches.clear()
    }
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
    return token >= 0 and token <= 4611686018427387903   # < 2^62
}

# poll(2) revents -> Event.events bits; POLLNVAL is handled by the caller.
def poll_bits(rev: int) -> int {
    bits = 0
    if (rev & 1) != 0 {
        bits = bits | 1
    }
    if (rev & 4) != 0 {
        bits = bits | 4
    }
    if (rev & 8) != 0 {
        bits = bits | 8
    }
    if (rev & 16) != 0 {
        bits = bits | 16
    }
    if (rev & 8192) != 0 {
        bits = bits | 8192
    }
    return bits
}

# Event.events -> pollfd.events; only readable/writable/half-close are meaningful under poll.
def poll_events(events: int) -> int {
    want = events & 5
    if (events & 8192) != 0 {
        want = want | 8192
    }
    return want
}

def set_pollfd(b: str, off: int, fd: int, events: int) {
    buf_set32(b, off, fd)
    buf_set8(b, off + 4, events % 256)
    buf_set8(b, off + 5, (events / 256) % 256)
    buf_set8(b, off + 6, 0)
    buf_set8(b, off + 7, 0)
}

def make_event(events: int, token: int) -> Event {
    e = Event()
    e.token = token
    e.events = events
    return e
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

# Connected UDP loopback pair: a wake message survives as one datagram per post, so
# concurrent posts stay distinct, unlike a byte-stream pipe that can merge writes.
def make_wake_pair() -> WakePair {
    p = WakePair()
    p.ok = False
    p.error = ""
    p.r = -1
    p.w = -1
    e = 0
    r = socket(2, 2, 0)   # AF_INET / SOCK_DGRAM
    if r < 0 {
        e = errno_code()
    }
    w = -1
    if e == 0 {
        w = socket(2, 2, 0)
        if w < 0 {
            e = errno_code()
        }
    }
    a = buf_alloc(32)
    buf_zero(a, 32)
    buf_set32(a, 0, 2)   # AF_INET, port 0 (wildcard bind)
    if e == 0 {
        rc1 = bind(r, a, 16)
        if rc1 != 0 {
            e = errno_code()
        }
    }
    if e == 0 {
        lp1 = buf_alloc(4)
        buf_set32(lp1, 0, 16)
        rc2 = getsockname(r, a, lp1)
        if rc2 != 0 {
            e = errno_code()
        }
        buf_free(lp1)
    }
    if e == 0 {
        buf_set8(a, 4, 127)   # 127.0.0.1 in network byte order
        buf_set8(a, 5, 0)
        buf_set8(a, 6, 0)
        buf_set8(a, 7, 1)
        rc3 = connect(w, a, 16)
        if rc3 != 0 {
            e = errno_code()
        }
    }
    if e == 0 {
        buf_zero(a, 16)
        buf_set32(a, 0, 2)
        lp2 = buf_alloc(4)
        buf_set32(lp2, 0, 16)
        rc4 = getsockname(w, a, lp2)
        if rc4 != 0 {
            e = errno_code()
        }
        buf_free(lp2)
    }
    if e == 0 {
        buf_set8(a, 4, 127)
        buf_set8(a, 5, 0)
        buf_set8(a, 6, 0)
        buf_set8(a, 7, 1)
        rc5 = connect(r, a, 16)
        if rc5 != 0 {
            e = errno_code()
        }
    }
    buf_free(a)
    if e != 0 {
        if r >= 0 {
            close(r)
        }
        if w >= 0 {
            close(w)
        }
        p.error = error_text(e)
        return p
    }
    set_nonblocking(r, True)
    p.ok = True
    p.r = r
    p.w = w
    return p
}

public def new_loop() -> EventLoop {
    l = EventLoop()
    l.epfd = -1
    l.wake_r = -1
    l.wake_w = -1
    l.timers = List[TimerWatch]()
    l.watches = List[Watch]()
    l.error = ""
    p = make_wake_pair()
    if not p.ok {
        l.error = p.error
        return l
    }
    l.epfd = 1
    l.wake_r = p.r
    l.wake_w = p.w
    return l
}

public def errno_value() -> int {
    return errno_code()
}

# One-shot readiness wait without constructing an EventLoop.
# Returns 1 when ready, 0 on timeout, -1 on error. Intended for async wrappers that
# wait in short slices and poll asyncio.cancelled() between slices.
public def wait_fd(fd: int, events: int, timeout_ms: int) -> int {
    if fd < 0 {
        return -1
    }
    fds = buf_alloc(8)
    buf_zero(fds, 8)
    set_pollfd(fds, 0, fd, poll_events(events))
    n = -1
    while True {
        n = poll(fds, 1, timeout_ms)
        if n < 0 and errno_code() == 4 {   # EINTR
            continue
        }
        break
    }
    buf_free(fds)
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
