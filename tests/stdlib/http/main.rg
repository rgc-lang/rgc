# http: keep-alive, redirects, chunked, gzip, Cookie, proxy, limits, timeout, binary responses
#
# The parent process starts itself with `--serve` as a minimal HTTP/1.1 server; the server writes its port to a file,
# then serially processes connections in the same process (keep-alive connections read multiple requests in a row).

import asyncio
import bytes
import gzip
import http
import io
import net
import os
import string
import time

class Conn {
    s: TcpStream
    buf: Bytes

    def fill(self) -> bool {
        r = self.s.recv_bytes(16384)
        if not r.ok {
            return False
        }
        if r.value.len == 0 {
            return False
        }
        self.buf.append(r.value)
        return True
    }

    # Read up to \r\n\r\n (exclusive); returns "" on EOF or error.
    def read_head(self) -> str {
        while True {
            idx = self.buf.find("\r\n\r\n", 0)
            if idx >= 0 {
                head = buf_to_str(self.buf.data, idx)
                self.buf.drop_front(idx + 4)
                return head
            }
            if not self.fill() {
                return ""
            }
        }
    }

    def read_body(self, n: int) -> Bytes {
        while self.buf.len < n {
            if not self.fill() {
                break
            }
        }
        if self.buf.len < n {
            out = self.buf.slice(0, self.buf.len)
            self.buf.clear()
            return out
        }
        out = self.buf.slice(0, n)
        self.buf.drop_front(n)
        return out
    }
}

def bytes_from_ints(vals: List[int]) -> Bytes {
    b = bytes.bytes_new(vals.len())
    for v in vals {
        b.push(v)
    }
    return b
}

# gzip("compressed payload")
def gzip_payload() -> Bytes {
    vals = List[int]()
    vals.push(31)
    vals.push(139)
    vals.push(8)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(2)
    vals.push(255)
    vals.push(75)
    vals.push(206)
    vals.push(207)
    vals.push(45)
    vals.push(40)
    vals.push(74)
    vals.push(45)
    vals.push(46)
    vals.push(78)
    vals.push(77)
    vals.push(81)
    vals.push(40)
    vals.push(72)
    vals.push(172)
    vals.push(204)
    vals.push(201)
    vals.push(79)
    vals.push(76)
    vals.push(1)
    vals.push(0)
    vals.push(36)
    vals.push(26)
    vals.push(216)
    vals.push(213)
    vals.push(18)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    return bytes_from_ints(vals)
}

# zlib.compress("compressed payload")
def zlib_payload() -> Bytes {
    vals = List[int]()
    vals.push(120)
    vals.push(156)
    vals.push(75)
    vals.push(206)
    vals.push(207)
    vals.push(45)
    vals.push(40)
    vals.push(74)
    vals.push(45)
    vals.push(46)
    vals.push(78)
    vals.push(77)
    vals.push(81)
    vals.push(40)
    vals.push(72)
    vals.push(172)
    vals.push(204)
    vals.push(201)
    vals.push(79)
    vals.push(76)
    vals.push(1)
    vals.push(0)
    vals.push(69)
    vals.push(197)
    vals.push(7)
    vals.push(64)
    return bytes_from_ints(vals)
}

def binary_payload() -> Bytes {
    b = bytes.bytes_new(256)
    i = 0
    while i < 256 {
        b.push(i)
        i = i + 1
    }
    return b
}

# gzip("A" * 10000): 46 bytes compressed, 10000 bytes decompressed (zip bomb)
def gzip_bomb_payload() -> Bytes {
    vals = List[int]()
    vals.push(31)
    vals.push(139)
    vals.push(8)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(2)
    vals.push(255)
    vals.push(237)
    vals.push(193)
    vals.push(1)
    vals.push(13)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(194)
    vals.push(160)
    vals.push(108)
    vals.push(239)
    vals.push(95)
    vals.push(202)
    vals.push(28)
    vals.push(110)
    vals.push(64)
    vals.push(1)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(0)
    vals.push(192)
    vals.push(191)
    vals.push(1)
    vals.push(237)
    vals.push(200)
    vals.push(67)
    vals.push(60)
    vals.push(16)
    vals.push(39)
    vals.push(0)
    vals.push(0)
    return bytes_from_ints(vals)
}

def wire(c: @var Conn, raw: str) -> bool {
    n = c.s.send(raw)
    return n == raw.len()
}

def wire_bytes(c: @var Conn, data: Bytes) -> bool {
    n = c.s.send_bytes(data)
    return n == data.len
}

def respond(c: @var Conn, status: str, extra: str, body: str) -> bool {
    raw = "HTTP/1.1 " + status + "\r\n" + extra + "Content-Length: " +
          to_string(body.len()) + "\r\n\r\n" + body
    return wire(c, raw)
}

def respond_bytes(c: @var Conn, status: str, extra: str, body: Bytes) -> bool {
    head = "HTTP/1.1 " + status + "\r\n" + extra + "Content-Length: " +
           to_string(body.len) + "\r\n\r\n"
    data = bytes.bytes_from_str(head)
    data.append(body)
    return wire_bytes(c, data)
}

def serve(port_file: str) {
    l = net.listen_on("127.0.0.1", 0)
    if not l.ok {
        return
    }
    listener = l.listener
    port = listener.local_port()
    wr = io.write_file(port_file, to_string(port))
    if not wr.is_ok() {
        listener.close()
        return
    }

    conn_no = 0
    running = True
    while running {
        a = listener.accept()
        if not a.ok {
            break
        }
        conn_no = conn_no + 1
        c = Conn()
        c.s = a.stream
        c.buf = bytes.bytes_new(0)

        while running {
            head = c.read_head()
            if head.len() == 0 {
                break
            }
            lines = head.split("\r\n")
            first = lines.get(0)
            words = string.split_whitespace(first)
            method = ""
            target = "/"
            if words.len() > 1 {
                method = words.get(0)
                target = words.get(1)
            }

            cl = 0
            x_test = ""
            cookie = ""
            content_encoding = ""
            close_conn = False
            for line in lines {
                low = string.to_lower(line)
                if low.startswith("content-length:") {
                    cl = string.trim(line.slice(15, line.len())).to_int().unwrap()
                    pass
                } elif low.startswith("x-test:") {
                    x_test = string.trim(line.slice(7, line.len()))
                    pass
                } elif low.startswith("cookie:") {
                    cookie = string.trim(line.slice(7, line.len()))
                    pass
                } elif low.startswith("content-encoding:") {
                    content_encoding = string.trim(line.slice(17, line.len()))
                    pass
                } elif low.startswith("connection:") {
                    if low.contains("close") {
                        close_conn = True
                    }
                    pass
                }
                pass
            }
            body = c.read_body(cl)

            path = target
            qi = string.find(target, "?")
            if qi >= 0 {
                path = target.slice(0, qi)
            }

            if target.startswith("http://") {
                respond(c, "200 OK", "X-Proxy: yes\r\n", "proxied " + path)
                pass
            } elif path == "/hello" {
                if method == "HEAD" {
                    wire(c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" +
                            "X-Test: one\r\nContent-Length: 12\r\n\r\n")
                } else {
                    respond(c, "200 OK", "Content-Type: text/plain\r\nX-Test: one\r\n",
                            "hello, world")
                }
                pass
            } elif path == "/conn" {
                respond(c, "200 OK", "X-Conn: " + to_string(conn_no) + "\r\n", "conn")
                pass
            } elif path == "/echo" {
                respond(c, "201 Created", "X-Method: " + method + "\r\n",
                        "echo:" + body.to_str())
                pass
            } elif path == "/echo-gzip" {
                if content_encoding == "gzip" {
                    d = gzip.decompress(@body)
                    if d.ok {
                        respond(c, "200 OK", "X-Was-Gzip: yes\r\n",
                                "echo:" + d.data.to_str())
                    } else {
                        respond(c, "400 Bad Request", "", "bad gzip")
                    }
                } else {
                    respond(c, "400 Bad Request", "", "not gzip")
                }
                pass
            } elif path == "/headers" {
                respond(c, "200 OK", "", x_test)
                pass
            } elif path == "/query" {
                respond(c, "200 OK", "", target)
                pass
            } elif path == "/setcookie" {
                respond(c, "200 OK", "Set-Cookie: sid=abc123; Path=/\r\n", "set")
                pass
            } elif path == "/cookie" {
                respond(c, "200 OK", "", cookie)
                pass
            } elif path == "/redirect" {
                respond(c, "302 Found", "Location: /hello\r\n", "")
                pass
            } elif path == "/redirect-abs" {
                loc = "http://127.0.0.1:" + to_string(port) + "/hello"
                respond(c, "301 Moved Permanently", "Location: " + loc + "\r\n", "")
                pass
            } elif path == "/chunked" {
                wire(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" +
                        "Content-Type: text/plain\r\n\r\n6\r\nchunk1\r\n1\r\n!\r\n" +
                        "0\r\nX-Trailer: yes\r\n\r\n")
                pass
            } elif path == "/gzip" {
                respond_bytes(c, "200 OK", "Content-Encoding: gzip\r\n", gzip_payload())
                pass
            } elif path == "/deflate" {
                respond_bytes(c, "200 OK", "Content-Encoding: deflate\r\n", zlib_payload())
                pass
            } elif path == "/gzip-bomb" {
                respond_bytes(c, "200 OK", "Content-Encoding: gzip\r\n",
                              gzip_bomb_payload())
                pass
            } elif path == "/big" {
                respond(c, "200 OK", "", "01234567890123456789")
                pass
            } elif path == "/bigheader" {
                respond(c, "200 OK", "X-Big: " + string.repeat("a", 300) + "\r\n", "ok")
                pass
            } elif path == "/slow" {
                time.sleep(0.4)
                respond(c, "200 OK", "", "slow")
                pass
            } elif path == "/early" {
                wire(c, "HTTP/1.1 100 Continue\r\n\r\n")
                respond(c, "200 OK", "", "after 100")
                pass
            } elif path == "/no-content" {
                wire(c, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                pass
            } elif path == "/binary" {
                respond_bytes(c, "200 OK", "", binary_payload())
                pass
            } elif path == "/quit" {
                respond(c, "200 OK", "", "bye")
                running = False
                pass
            } else {
                respond(c, "404 Not Found", "", "not found")
                pass
            }

            if close_conn or not running {
                break
            }
        }
        c.s.close()
    }
    listener.close()
}

def main() -> int {
    argv = args()
    if argv.len() > 2 and argv.get(1) == "--serve" {
        serve(argv.get(2))
        return 0
    }

    port_file = "/tmp/rgc_stdlib_http.port"
    io.remove_file(port_file)
    cmd = "'" + argv.get(0) + "' --serve '" + port_file +
          "' >/dev/null 2>&1 & p=$!; (sleep 10; kill $p 2>/dev/null) &"
    os.system(cmd)

    port = 0
    tries = 0
    while tries < 500 {
        if io.exists(port_file) {
            break
        }
        time.sleep(0.01)
        tries = tries + 1
    }
    if io.exists(port_file) {
        fr = io.read_file(port_file)
        if fr.is_ok() {
            port = fr.unwrap().to_int().unwrap()
        }
    }
    if port == 0 {
        print("server_start False")
        return 1
    }
    print("server_start True")

    base = "http://127.0.0.1:" + to_string(port)

    r = http.get(base + "/hello")
    print("get", r.ok, r.response.status, r.response.body)
    if r.ok {
        res = r.response
        print("get_header", http.header(@res, "Content-Type"),
              http.header(@res, "X-Test"))
    }

    hs = List[str]()
    hs.push("X-Test: custom")
    h = http.get_with(base + "/headers", hs)
    print("custom_header", h.ok, h.response.body)

    p = http.post(base + "/echo", "ping")
    print("post", p.ok, p.response.status, p.response.body)

    zc = http.new_client()
    zc.compress_request = True
    zr = zc.post(base + "/echo-gzip", "compressed request body")
    print("request_gzip", zr.ok, zr.response.status, zr.response.body)
    if zr.ok {
        zres = zr.response
        print("request_gzip_header", http.header(@zres, "X-Was-Gzip"))
    } else {
        print("request_gzip_header []")
    }
    zc.close()

    ck = http.get(base + "/chunked")
    print("chunked", ck.ok, ck.response.status, ck.response.body)
    if ck.ok {
        cr = ck.response
        print("trailer", http.trailer(@cr, "X-Trailer"), cr.trailers.len())
    } else {
        print("trailer [] 0")
    }

    kc = http.new_client()
    k1 = kc.get(base + "/conn")
    k2 = kc.get(base + "/conn")
    if k1.ok and k2.ok {
        ka = k1.response
        kb = k2.response
        print("keepalive", http.header(@ka, "X-Conn") == http.header(@kb, "X-Conn"))
    } else {
        print("keepalive False")
    }
    kc.close()

    rd = http.get(base + "/redirect")
    print("redirect", rd.ok, rd.response.status, rd.response.body,
          rd.response.url.endswith("/hello"))

    ra = http.get(base + "/redirect-abs")
    print("redirect_abs", ra.ok, ra.response.status, ra.response.body)

    cc = http.new_client()
    s1 = cc.get(base + "/setcookie")
    s2 = cc.get(base + "/cookie")
    print("cookie", s1.ok, s2.ok, s2.response.body)
    cc.close()

    g = http.get(base + "/gzip")
    print("gzip", g.ok, g.response.body)
    d = http.get(base + "/deflate")
    print("deflate", d.ok, d.response.body)

    lc = http.new_client()
    lc.max_body = 10
    mb = lc.get(base + "/big")
    print("max_body", mb.ok, mb.error)
    lc.close()

    bc = http.new_client()
    bc.max_body = 100
    bomb = bc.get(base + "/gzip-bomb")
    print("gzip_bomb", bomb.ok, bomb.error)
    bc.close()

    hc = http.new_client()
    hc.max_header = 200
    mh = hc.get(base + "/bigheader")
    print("max_header", mh.ok, mh.error)
    hc.close()

    tc = http.new_client()
    tc.timeout_ms = 150
    st = tc.get(base + "/slow")
    print("timeout", st.ok, st.error)
    tc.close()

    e = http.get(base + "/early")
    print("early", e.ok, e.response.status, e.response.body)

    hd = http.request("HEAD", base + "/hello", "")
    print("head", hd.ok, hd.response.status, hd.response.body.len())

    nc = http.get(base + "/no-content")
    print("no_content", nc.ok, nc.response.status, nc.response.body.len())

    bn = http.get(base + "/binary")
    if bn.ok {
        bb = bn.response.body_bytes
        print("binary", bb.len, bb.get(0), bb.get(255))
    } else {
        print("binary False")
    }

    q = http.get(base + "/query?x=1&y=2")
    print("query", q.ok, q.response.body)

    pairs = List[str]()
    pairs.push("q=a b")
    pairs.push("x=1")
    print("query_encode", http.encode_query(pairs))
    dq = http.decode_query("q=hello+world&x=%E4%BD%A0")
    print("query_decode", dq.get(0), dq.get(1))

    pc = http.new_client()
    pc.proxy = "http://127.0.0.1:" + to_string(port)
    pr = pc.get("http://example.invalid/hello?x=1")
    print("proxy", pr.ok, pr.response.status, pr.response.body)
    pc.close()

    bad = http.get("ftp://127.0.0.1/")
    print("bad_scheme", bad.ok, bad.error)
    no_host = http.get("http://")
    print("no_host", no_host.ok, no_host.error)
    bad_port = http.get("http://127.0.0.1:70000/")
    print("bad_port", bad_port.ok, bad_port.error)
    refused = http.get("http://127.0.0.1:1/")
    print("refused", refused.ok, refused.error.len() > 0)

    ar = asyncio.run(http.get_async(base + "/hello"))
    print("async_get", ar.ok, ar.response.status)

    tasks = List[Task[HttpResult]]()
    tasks.push(http.get_async(base + "/hello"))
    tasks.push(http.get_async(base + "/conn"))
    ars = asyncio.run(asyncio.gather(tasks))
    print("async_gather", ars.len(), ars.get(0).ok, ars.get(1).ok)

    qq = http.get(base + "/quit")
    print("quit", qq.ok, qq.response.status)

    io.remove_file(port_file)
    return 0
}
