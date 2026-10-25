# RGC standard library: http
#
# Synchronous HTTP client: HTTP/1.1 (plaintext/TLS) and HTTP/2 (TLS + ALPN h2), redirects,
# gzip/deflate decompression, keep-alive connection pool, custom headers, query-string encode/decode, Cookie,
# HTTP proxy, and limits.
# The language does not yet support Result[custom types]; results are carried by HttpResult { ok, error, response }.
#
# Usage:
#   import http
#   r = http.get("http://127.0.0.1:8080/")
#   if r.ok {
#       print(r.response.status)
#       print(http.header(@r.response, "Content-Type"))
#       print(r.response.body)
#   } else {
#       print("request failed:", r.error)
#   }
#
#   c = http.new_client()            # reuse connections + Cookie + custom headers
#   c.add_header("X-Token", "abc")
#   a = c.get("http://127.0.0.1:8080/a")
#   b = c.post("http://127.0.0.1:8080/b", "data")
#   c.close()
#
# Semantics:
#   - One HttpResult layer wraps errors; response.body is a C-string view,
#     response.body_bytes is the binary-safe response body (already decompressed per Content-Encoding).
#   - Follows 301/302/303/307/308 by default, up to max_redirects times; 303 and POST's
#     301/302 are rewritten to GET.
#   - Requests Accept-Encoding: gzip, deflate by default; other encodings like br are unsupported.
#   - Response bodies support Content-Length, chunked (with trailers), and EOF delimiting.
#   - 1xx intermediate responses are skipped; 204/304/HEAD have no body.
#   - keep-alive is on by default (HttpClient); module-level http.get/post use one-shot connections.
#   - HTTP/2 is on by default: the https handshake offers h2 via ALPN, and the http2 module is used when selected;
#     otherwise it falls back to HTTP/1.1. Set http2 = False to disable. version is "HTTP/2".
#     An HTTP/2 connection runs only one stream at a time (sequential reuse); server push and h2c are unsupported.
#   - Idle connections are probed with poll+MSG_PEEK before reuse; stale connections are retried once (idempotent methods).
#   - Timeouts: connect_timeout_ms controls connect/handshake; timeout_ms controls reads/writes (0 means unlimited).
#   - Limits: max_header (default 64 KiB), max_body (default 32 MiB, checked again after decompression).
#   - Proxy: proxy = "http://[user:pass@]host:port"; http uses absolute-form,
#     https uses a CONNECT tunnel. An https:// proxy itself is unsupported.
#   - DNS resolution (getaddrinfo) has no separate timeout; TLS and gzip/deflate are pure RGC
#     (lib/tls.rg and lib/gzip.rg, no external crypto library).

import asyncio
import net
import tls
import http2
import gzip
import bytes
import string

public class HttpResponse {
    status: int
    version: str
    headers: List[str]
    trailers: List[str]
    body: str
    body_bytes: Bytes
    url: str
}

public class HttpResult {
    ok: bool
    error: str
    response: HttpResponse
}

public class UrlParts {
    ok: bool
    error: str
    scheme: str
    host: str
    port: int
    authority: str
    path: str
    query: str
    userinfo: str
    tls: bool
}

public class HttpCookie {
    name: str
    value: str
    domain: str
    path: str
    secure: bool
    host_only: bool
    max_age: int
}

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------

# kind: 0 = plaintext TCP, 1 = TLS/HTTP1.1, 2 = TLS/HTTP2.
public class HttpConn {
    kind: int
    fd: int
    tcp: TcpStream
    tls: TlsConn
    h2: H2Conn
    host: str
    port: int
    open: bool

    def send(self, data: str) -> int {
        return self.send_mem(data, data.len())
    }

    def send_mem(self, p: str, n: int) -> int {
        if not self.open {
            return 0
        }
        if self.kind == 1 {
            return self.tls.send_mem(p, n)
        }
        return self.tcp.send_mem(p, n)
    }

    def recv_bytes(self, max: int) -> TcpRecvBytes {
        if self.kind == 1 {
            return self.tls.recv_bytes(max)
        }
        return self.tcp.recv_bytes(max)
    }

    def close(self) {
        if self.fd >= 0 {
            if self.kind == 2 {
                self.h2.close()
            } elif self.kind == 1 {
                self.tls.close()
            } else {
                self.tcp.close()
            }
            self.fd = -1
        }
        self.open = False
    }

    # Idle-connection liveness: True when the peer closed or errored.
    def is_stale(self) -> bool {
        if not self.open or self.fd < 0 {
            return True
        }
        if self.kind == 2 {
            if self.h2.closed or self.h2.goaway or self.h2.eof {
                return True
            }
        }
        return net.fd_is_closed(self.fd)
    }
}

class PooledConn {
    conn: HttpConn
    host: str
    port: int
    kind: int
    buf: Bytes
}

class HeadResult {
    ok: bool
    error: str
    version: str
    status: int
    headers: List[str]
}

class TunnelResult {
    ok: bool
    error: str
}

class ConnResult {
    ok: bool
    error: str
    conn: HttpConn
    buf: Bytes
    reused: bool
}

class Exchange {
    ok: bool
    error: str
    reused: bool
    status: int
    version: str
    headers: List[str]
    trailers: List[str]
    body: Bytes
}

# ---------------------------------------------------------------------------
# Streaming reads (byte-buffered; supports CRLF lines, fixed-length, chunked, and EOF delimiting)
# ---------------------------------------------------------------------------

class StreamReader {
    conn: HttpConn
    buf: Bytes
    eof: bool
    err: str
    line_complete: bool
    max_header: int
    trailers: List[str]

    def fill(self) -> bool {
        if self.eof {
            return False
        }
        r = self.conn.recv_bytes(16384)
        if not r.ok {
            self.err = r.error
            self.eof = True
            return False
        }
        if r.value.len == 0 {
            self.eof = True
            return False
        }
        self.buf.append_mem(r.value.data, r.value.len)
        return True
    }

    # Read a line without CRLF; line_complete indicates the line was fully read (not truncated by EOF).
    def read_line(self) -> str {
        if self.err.len() > 0 {
            return ""
        }
        while True {
            idx = self.buf.find("\r\n", 0)
            if idx >= 0 {
                line = buf_to_str(self.buf.data, idx)
                self.buf.drop_front(idx + 2)
                self.line_complete = True
                return line
            }
            if self.buf.len > self.max_header {
                self.err = "response header too large"
                return ""
            }
            if self.eof {
                self.line_complete = False
                return ""
            }
            if not self.fill() {
                if self.err.len() == 0 {
                    self.line_complete = False
                }
                return ""
            }
        }
    }

    def read_n(self, n: int) -> Bytes {
        if n < 0 {
            self.err = "invalid content length"
            return bytes.bytes_new(0)
        }
        if n == 0 {
            return bytes.bytes_new(0)
        }
        while self.buf.len < n {
            if self.eof {
                break
            }
            if not self.fill() {
                break
            }
        }
        if self.buf.len < n {
            if self.err.len() == 0 {
                self.err = "unexpected end of response"
            }
            return bytes.bytes_new(0)
        }
        out = self.buf.slice(0, n)
        self.buf.drop_front(n)
        return out
    }

    def read_all(self, limit: int) -> Bytes {
        out = bytes.bytes_new(self.buf.len + 64)
        while True {
            if self.buf.len > 0 {
                if limit > 0 and out.len + self.buf.len > limit {
                    self.err = "response body too large"
                    return bytes.bytes_new(0)
                }
                out.append_mem(self.buf.data, self.buf.len)
                self.buf.clear()
            }
            if self.eof {
                break
            }
            if not self.fill() {
                break
            }
        }
        if self.err.len() > 0 {
            return bytes.bytes_new(0)
        }
        return out
    }

    def read_chunked(self, limit: int) -> Bytes {
        out = bytes.bytes_new(256)
        while True {
            line = self.read_line()
            if self.err.len() > 0 {
                return bytes.bytes_new(0)
            }
            if not self.line_complete {
                self.err = "unexpected end of response"
                return bytes.bytes_new(0)
            }
            semi = string.find(line, ";")
            size_text = line
            if semi >= 0 {
                size_text = line.slice(0, semi)
            }
            size = hex_to_int(string.trim(size_text))
            if size < 0 {
                self.err = "malformed chunk size"
                return bytes.bytes_new(0)
            }
            if size == 0 {
                # trailer: read lines until the empty line, keeping them for the caller to query.
                while True {
                    trailer = self.read_line()
                    if self.err.len() > 0 {
                        return bytes.bytes_new(0)
                    }
                    if not self.line_complete {
                        self.err = "malformed chunked body"
                        return bytes.bytes_new(0)
                    }
                    if trailer.len() == 0 {
                        break
                    }
                    self.trailers.push(trailer)
                }
                break
            }
            if limit > 0 and out.len + size > limit {
                self.err = "response body too large"
                return bytes.bytes_new(0)
            }
            data = self.read_n(size)
            if self.err.len() > 0 {
                return bytes.bytes_new(0)
            }
            out.append_mem(data.data, data.len)
            end_line = self.read_line()
            if self.err.len() > 0 {
                return bytes.bytes_new(0)
            }
            if not self.line_complete or end_line.len() != 0 {
                self.err = "malformed chunked body"
                return bytes.bytes_new(0)
            }
        }
        return out
    }

    def take_leftover(self) -> Bytes {
        n = self.buf.len
        if n == 0 {
            return bytes.bytes_new(0)
        }
        out = self.buf.slice(0, n)
        self.buf.clear()
        return out
    }
}

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

public class HttpClient {
    timeout_ms: int
    connect_timeout_ms: int
    max_redirects: int
    max_body: int
    max_header: int
    max_idle: int
    proxy: str
    ca_file: str
    client_cert: str
    client_key: str
    verify_tls: bool
    keep_alive: bool
    follow_redirects: bool
    compress_request: bool
    http2: bool
    headers: List[str]
    cookies: List[HttpCookie]
    idle: List[PooledConn]

    # ---- simple request entries ----

    def get(self, url: str) -> HttpResult {
        empty = List[str]()
        return self.exec("GET", url, "", 0, False, empty, "")
    }

    def get_with(self, url: str, headers: List[str]) -> HttpResult {
        return self.exec("GET", url, "", 0, False, headers, "")
    }

    def post(self, url: str, body: str) -> HttpResult {
        n = body.len()
        empty = List[str]()
        return self.exec("POST", url, body, n, True, empty,
                         "text/plain; charset=utf-8")
    }

    def post_with(self, url: str, body: str, headers: List[str]) -> HttpResult {
        n = body.len()
        return self.exec("POST", url, body, n, True, headers,
                         "text/plain; charset=utf-8")
    }

    def request(self, method: str, url: str, body: str) -> HttpResult {
        n = body.len()
        empty = List[str]()
        return self.exec(method, url, body, n, True, empty,
                         "text/plain; charset=utf-8")
    }

    def request_with(self, method: str, url: str, body: str, headers: List[str]) -> HttpResult {
        n = body.len()
        return self.exec(method, url, body, n, True, headers,
                         "text/plain; charset=utf-8")
    }

    def request_bytes(self, method: str, url: str, body: @Bytes,
                      headers: List[str]) -> HttpResult {
        n = body.len
        return self.exec(method, url, body.data, n, True, headers,
                         "application/octet-stream")
    }

    # user:pass in the URL automatically generates Authorization.
    def exec(self, method: str, url: str, body_ptr: str, body_len: int, has_body: bool,
             extra: List[str], content_type: str) -> HttpResult {
        if not valid_method(method) {
            return fail_result("invalid method")
        }
        if not url_chars_ok(url) {
            return fail_result("invalid URL")
        }
        headers = self.merge_headers(extra)
        if not validate_headers(headers) {
            return fail_result("invalid header")
        }

        cur_url = url
        cur_method = method
        cur_ptr = body_ptr
        cur_len = body_len
        cur_has = has_body
        cur_type = content_type
        redirects = 0
        retried = False

        comp = bytes.bytes_new(0)
        if self.compress_request and cur_has and cur_len > 0 {
            if not has_header(headers, "Content-Encoding") {
                src = bytes.bytes_from_mem(cur_ptr, cur_len)
                gz = gzip.compress(@src)
                if not gz.ok {
                    return fail_result("request compression failed: " + gz.error)
                }
                comp = gz.data
                cur_ptr = comp.data
                cur_len = comp.len
                headers = strip_header(headers, "Content-Length")
                headers.push("Content-Encoding: gzip")
            }
        }

        while True {
            p = parse_url(cur_url)
            if not p.ok {
                return fail_result(p.error)
            }
            ex = self.exchange(cur_method, p, cur_ptr, cur_len, cur_has, headers, cur_type)
            if not ex.ok {
                if ex.reused and not retried and is_retryable(cur_method) {
                    retried = True
                    continue
                }
                return fail_result(ex.error)
            }
            retried = False

            if self.follow_redirects and is_redirect(ex.status) {
                loc = header_in(ex.headers, "Location")
                if loc.len() > 0 {
                    if redirects >= self.max_redirects {
                        return fail_result("too many redirects")
                    }
                    next_url = resolve_url(cur_url, loc)
                    np = parse_url(next_url)
                    if not np.ok {
                        return fail_result("invalid redirect URL")
                    }
                    if np.host != p.host {
                        headers = strip_header(headers, "Authorization")
                        headers = strip_header(headers, "Host")
                    }
                    if redirect_makes_get(ex.status, cur_method) {
                        cur_method = "GET"
                        cur_ptr = ""
                        cur_len = 0
                        cur_has = False
                        cur_type = ""
                        headers = strip_header(headers, "Content-Encoding")
                    }
                    cur_url = next_url
                    redirects = redirects + 1
                    continue
                }
            }

            resp = make_response(ex, cur_url)
            out = HttpResult()
            out.ok = True
            out.error = ""
            out.response = resp
            return out
        }
    }

    # ---- one-shot send/receive (connection acquisition, request construction, response parsing, connection return) ----

    def exchange(self, method: str, p: @UrlParts, body_ptr: str, body_len: int,
                 has_body: bool, headers: @List[str], content_type: str) -> Exchange {
        ex = Exchange()
        ex.ok = False
        ex.error = ""
        ex.reused = False
        ex.status = 0
        ex.version = ""
        ex.headers = List[str]()
        ex.trailers = List[str]()
        ex.body = bytes.bytes_new(0)

        cr = self.acquire(p)
        if not cr.ok {
            ex.error = cr.error
            return ex
        }
        ex.reused = cr.reused

        conn = cr.conn
        status = 0
        version = ""
        hdrs = List[str]()
        trls = List[str]()
        body = bytes.bytes_new(0)
        leftover = bytes.bytes_new(0)
        keep = False

        if conn.kind == 2 {
            target = request_target(p)
            hh = self.h2_request_headers(p, body_len, has_body, headers, content_type)
            hr2 = http2.request(conn.h2, method, "https", p.authority, target, hh,
                                body_ptr, body_len, has_body and body_len > 0,
                                self.max_header, self.max_body)
            if not hr2.ok {
                conn.close()
                ex.error = hr2.error
                return ex
            }
            status = hr2.status
            version = "HTTP/2"
            hdrs = hr2.headers
            trls = hr2.trailers
            body = hr2.body
            keep = self.keep_alive and not hr2.conn_closed
        } else {
            via_proxy = self.proxy.len() > 0
            proxy_auth = ""
            if via_proxy {
                pp = parse_proxy(self.proxy)
                if pp.ok {
                    proxy_auth = pp.auth
                }
            }
            proxy_abs = via_proxy and not p.tls
            if p.tls {
                proxy_auth = ""
            }

            req = self.build_request(method, p, body_len, has_body, headers,
                                     proxy_abs, proxy_auth, content_type)
            sent = conn.send(req)
            if sent < req.len() {
                conn.close()
                ex.error = "send failed"
                return ex
            }
            if has_body and body_len > 0 {
                sent2 = conn.send_mem(body_ptr, body_len)
                if sent2 < body_len {
                    conn.close()
                    ex.error = "send failed"
                    return ex
                }
            }

            reader = StreamReader()
            reader.conn = conn
            reader.buf = cr.buf
            reader.eof = False
            reader.err = ""
            reader.line_complete = False
            reader.max_header = self.max_header
            reader.trailers = List[str]()

            hr = read_head(reader)
            if not hr.ok {
                reader.conn.close()
                ex.error = hr.error
                return ex
            }

            eof_body = False
            fatal = False
            te = header_in(hr.headers, "Transfer-Encoding")
            cl_text = header_in(hr.headers, "Content-Length")
            no_body = method == "HEAD" or hr.status == 204 or hr.status == 304 or hr.status == 101
            if no_body {
                body = bytes.bytes_new(0)
                pass
            } elif string.to_lower(te).contains("chunked") {
                body = reader.read_chunked(self.max_body)
                if reader.err.len() > 0 {
                    fatal = True
                }
                pass
            } elif string.trim(cl_text).len() > 0 {
                clr = string.trim(cl_text).to_int()
                if clr.is_err() {
                    reader.err = "invalid content-length"
                    fatal = True
                    pass
                } else {
                    cl = clr.unwrap()
                    if cl < 0 {
                        reader.err = "invalid content-length"
                        fatal = True
                        pass
                    } elif self.max_body > 0 and cl > self.max_body {
                        reader.err = "response body too large"
                        fatal = True
                        pass
                    } else {
                        body = reader.read_n(cl)
                        if reader.err.len() > 0 {
                            fatal = True
                        }
                        pass
                    }
                    pass
                }
                pass
            } else {
                body = reader.read_all(self.max_body)
                eof_body = True
                if reader.err.len() > 0 {
                    fatal = True
                }
                pass
            }
            if fatal {
                ex.error = reader.err
                reader.conn.close()
                return ex
            }

            status = hr.status
            version = hr.version
            hdrs = hr.headers
            trls = reader.trailers
            keep = self.keep_alive and not eof_body and hr.status != 101
            conn_hdr = string.to_lower(header_in(hr.headers, "Connection"))
            if conn_hdr.contains("close") {
                keep = False
            }
            if hr.version == "HTTP/1.0" and not conn_hdr.contains("keep-alive") {
                keep = False
            }

            leftover = reader.take_leftover()
            conn = reader.conn
        }

        enc = string.to_lower(string.trim(header_in(hdrs, "Content-Encoding")))
        if enc.len() > 0 and enc != "identity" {
            if enc == "gzip" or enc == "x-gzip" or enc == "deflate" {
                gz = gzip.decompress_limit(body, self.max_body)
                if not gz.ok {
                    conn.close()
                    if gz.error == "output limit exceeded" {
                        ex.error = "response body too large"
                    } else {
                        ex.error = "decompress failed: " + gz.error
                    }
                    return ex
                }
                body = gz.data
            } else {
                conn.close()
                ex.error = "unsupported content-encoding: " + enc
                return ex
            }
        }

        self.store_cookies(p, hdrs)

        if keep and not conn.is_stale() {
            self.release(conn, p, leftover)
        } else {
            conn.close()
        }

        ex.ok = True
        ex.status = status
        ex.version = version
        ex.headers = hdrs
        ex.trailers = trls
        ex.body = body
        return ex
    }

    # ---- connection acquisition and return ----

    def acquire(self, p: @UrlParts) -> ConnResult {
        r = ConnResult()
        r.ok = False
        r.error = ""
        r.conn = empty_conn()
        r.buf = bytes.bytes_new(0)
        r.reused = False

        if self.keep_alive {
            i = self.idle.len() - 1
            while i >= 0 {
                pc = self.idle.get(i)
                if pc.host == p.host and pc.port == p.port and
                   pool_conn_fits(pc.kind, p, self.http2) {
                    last = self.idle.len() - 1
                    if i != last {
                        self.idle.set(i, self.idle.get(last))
                    }
                    self.idle.pop()
                    if not pc.conn.is_stale() {
                        r.ok = True
                        r.conn = pc.conn
                        r.buf = pc.buf
                        r.reused = True
                        return r
                    }
                    pc.conn.close()
                }
                i = i - 1
            }
        }

        if self.proxy.len() > 0 {
            pp = parse_proxy(self.proxy)
            if not pp.ok {
                r.error = pp.error
                return r
            }
            c = net.connect_to_timeout(pp.host, pp.port, self.connect_timeout_ms)
            if not c.ok {
                r.error = c.error
                return r
            }
            if p.tls {
                s = c.stream
                s.set_timeout(self.connect_timeout_ms)
                tun = proxy_connect(s.fd, p.host, p.port, pp.auth, self.max_header)
                if not tun.ok {
                    s.close()
                    r.error = tun.error
                    return r
                }
                tr = tls.connect_on_alpn(s, p.host, self.verify_tls, self.ca_file,
                                         self.client_cert, self.client_key,
                                         self.connect_timeout_ms, self.http2)
                if not tr.ok {
                    tr.conn.close()
                    r.error = tr.error
                    return r
                }
                return tls_conn_result(tr, p, self.timeout_ms, self.http2)
            }
            c.stream.set_timeout(self.timeout_ms)
            r.conn = plain_http_conn(c.stream, p)
            r.ok = True
            return r
        }

        if p.tls {
            tr = tls.connect_alpn(p.host, p.port, self.connect_timeout_ms,
                                  self.verify_tls, self.ca_file,
                                  self.client_cert, self.client_key, self.http2)
            if not tr.ok {
                tr.conn.close()
                r.error = tr.error
                return r
            }
            return tls_conn_result(tr, p, self.timeout_ms, self.http2)
        }

        c = net.connect_to_timeout(p.host, p.port, self.connect_timeout_ms)
        if not c.ok {
            r.error = c.error
            return r
        }
        s = c.stream
        s.set_timeout(self.timeout_ms)
        r.conn = plain_http_conn(s, p)
        r.ok = True
        return r
    }

    def release(self, conn: HttpConn, p: @UrlParts, leftover: Bytes) {
        if self.max_idle <= 0 {
            conn.close()
            return
        }
        if self.idle.len() >= self.max_idle {
            old = self.idle.get(0)
            last = self.idle.len() - 1
            self.idle.set(0, self.idle.get(last))
            self.idle.pop()
            old.conn.close()
        }
        pc = PooledConn()
        k = conn.kind
        pc.conn = conn
        pc.host = p.host
        pc.port = p.port
        pc.kind = k
        pc.buf = leftover
        self.idle.push(pc)
    }

    def close(self) {
        i = self.idle.len() - 1
        while i >= 0 {
            pc = self.idle.get(i)
            pc.conn.close()
            i = i - 1
        }
        self.idle.clear()
    }

    # ---- request headers and Cookie ----

    def merge_headers(self, extra: @List[str]) -> List[str] {
        out = List[str]()
        i = 0
        while i < self.headers.len() {
            out.push(self.headers.get(i))
            i = i + 1
        }
        i = 0
        while i < extra.len() {
            out.push(extra.get(i))
            i = i + 1
        }
        return out
    }

    def build_request(self, method: str, p: @UrlParts, body_len: int, has_body: bool,
                      headers: @List[str], proxy_abs: bool, proxy_auth: str,
                      content_type: str) -> str {
        target = request_target(p)
        if proxy_abs {
            target = "http://" + p.authority + target
        }
        req = method + " " + target + " HTTP/1.1\r\n"
        if not has_header(headers, "Host") {
            req = req + "Host: " + p.authority + "\r\n"
        }
        if not has_header(headers, "User-Agent") {
            req = req + "User-Agent: rgc-http/1.1\r\n"
        }
        if not has_header(headers, "Accept") {
            req = req + "Accept: */*\r\n"
        }
        if not has_header(headers, "Accept-Encoding") {
            req = req + "Accept-Encoding: gzip, deflate\r\n"
        }
        if not has_header(headers, "Connection") {
            if self.keep_alive {
                req = req + "Connection: keep-alive\r\n"
            } else {
                req = req + "Connection: close\r\n"
            }
        }
        if not has_header(headers, "Cookie") {
            ck = self.cookie_header(p)
            if ck.len() > 0 {
                req = req + "Cookie: " + ck + "\r\n"
            }
        }
        if has_body and not has_header(headers, "Content-Length") {
            req = req + "Content-Length: " + to_string(body_len) + "\r\n"
        }
        if has_body and content_type.len() > 0 and not has_header(headers, "Content-Type") {
            req = req + "Content-Type: " + content_type + "\r\n"
        }
        if p.userinfo.len() > 0 and not has_header(headers, "Authorization") {
            req = req + "Authorization: Basic " + b64_encode(percent_decode(p.userinfo)) + "\r\n"
        }
        if proxy_auth.len() > 0 and not has_header(headers, "Proxy-Authorization") {
            req = req + "Proxy-Authorization: " + proxy_auth + "\r\n"
        }
        i = 0
        while i < headers.len() {
            req = req + headers.get(i) + "\r\n"
            i = i + 1
        }
        req = req + "\r\n"
        return req
    }

    # HTTP/2 request headers: pseudo-headers are generated by the http2 encoder; only normal headers go here.
    # Connection/Transfer-Encoding/Host etc. are filtered by the encoder per RFC 9113.
    def h2_request_headers(self, p: @UrlParts, body_len: int, has_body: bool,
                           headers: @List[str], content_type: str) -> List[str] {
        out = List[str]()
        if not has_header(headers, "User-Agent") {
            out.push("user-agent: rgc-http/2")
        }
        if not has_header(headers, "Accept") {
            out.push("accept: */*")
        }
        if not has_header(headers, "Accept-Encoding") {
            out.push("accept-encoding: gzip, deflate")
        }
        if not has_header(headers, "Cookie") {
            ck = self.cookie_header(p)
            if ck.len() > 0 {
                out.push("cookie: " + ck)
            }
        }
        if has_body and not has_header(headers, "Content-Length") {
            out.push("content-length: " + to_string(body_len))
        }
        if has_body and content_type.len() > 0 and not has_header(headers, "Content-Type") {
            out.push("content-type: " + content_type)
        }
        if p.userinfo.len() > 0 and not has_header(headers, "Authorization") {
            out.push("authorization: Basic " + b64_encode(percent_decode(p.userinfo)))
        }
        i = 0
        while i < headers.len() {
            out.push(headers.get(i))
            i = i + 1
        }
        return out
    }

    def add_header(self, name: str, value: str) {
        self.headers.push(name + ": " + value)
    }

    def set_header(self, name: str, value: str) {
        line = name + ": " + value
        i = 0
        while i < self.headers.len() {
            old = self.headers.get(i)
            colon = string.find(old, ":")
            if colon > 0 and string.to_lower(old.slice(0, colon)) == string.to_lower(name) {
                self.headers.set(i, line)
                return
            }
            i = i + 1
        }
        self.headers.push(line)
    }

    def set_proxy(self, proxy: str) {
        self.proxy = proxy
    }

    def set_ca_file(self, ca_file: str) {
        self.ca_file = ca_file
    }

    def set_client_cert(self, cert_file: str, key_file: str) {
        self.client_cert = cert_file
        self.client_key = key_file
    }

    def clear_cookies(self) {
        self.cookies.clear()
    }

    def cookie_header(self, p: @UrlParts) -> str {
        out = ""
        i = 0
        while i < self.cookies.len() {
            c = self.cookies.get(i)
            if cookie_matches(c, p) {
                if out.len() > 0 {
                    out = out + "; "
                }
                out = out + c.name + "=" + c.value
            }
            i = i + 1
        }
        return out
    }

    def store_cookies(self, p: @UrlParts, headers: @List[str]) {
        i = 0
        while i < headers.len() {
            line = headers.get(i)
            if string.to_lower(line).startswith("set-cookie:") {
                value = string.trim(line.slice(11, line.len()))
                c = parse_set_cookie(value, p)
                if c.name.len() > 0 and cookie_domain_ok(p.host, c) {
                    if c.max_age == 0 {
                        self.delete_cookie(c.name, c.domain, c.path)
                    } else {
                        self.put_cookie(c)
                    }
                }
            }
            i = i + 1
        }
    }

    def put_cookie(self, c: HttpCookie) {
        i = 0
        while i < self.cookies.len() {
            old = self.cookies.get(i)
            if old.name == c.name and old.domain == c.domain and old.path == c.path {
                self.cookies.set(i, c)
                return
            }
            i = i + 1
        }
        self.cookies.push(c)
    }

    def delete_cookie(self, name: str, domain: str, path: str) {
        keep = List[HttpCookie]()
        i = 0
        while i < self.cookies.len() {
            c = self.cookies.get(i)
            if c.name == name and c.domain == domain and c.path == path {
                pass
            } else {
                keep.push(c)
            }
            i = i + 1
        }
        self.cookies = keep
    }
}

# ---------------------------------------------------------------------------
# Construction and response helpers
# ---------------------------------------------------------------------------

public def new_client() -> HttpClient {
    c = HttpClient()
    c.timeout_ms = 30000
    c.connect_timeout_ms = 10000
    c.max_redirects = 10
    c.max_body = 33554432
    c.max_header = 65536
    c.max_idle = 8
    c.proxy = ""
    c.ca_file = ""
    c.client_cert = ""
    c.client_key = ""
    c.verify_tls = True
    c.keep_alive = True
    c.follow_redirects = True
    c.compress_request = False
    c.http2 = True
    c.headers = List[str]()
    c.cookies = List[HttpCookie]()
    c.idle = List[PooledConn]()
    return c
}

def one_shot_client() -> HttpClient {
    c = new_client()
    c.keep_alive = False
    return c
}

def dummy_stream() -> TcpStream {
    s = TcpStream()
    s.fd = -1
    s.timeout_ms = 0
    return s
}

def empty_tls_conn() -> TlsConn {
    t = TlsConn()
    t.ssl = ptr_null()
    t.ctx = ptr_null()
    t.tcp = dummy_stream()
    t.timeout_ms = 0
    return t
}

def empty_conn() -> HttpConn {
    c = HttpConn()
    c.kind = 0
    c.fd = -1
    c.tcp = dummy_stream()
    c.tls = empty_tls_conn()
    c.h2 = http2.empty_conn()
    c.host = ""
    c.port = 0
    c.open = False
    return c
}

def plain_http_conn(s: TcpStream, p: @UrlParts) -> HttpConn {
    c = HttpConn()
    c.kind = 0
    c.fd = s.fd
    c.tcp = s
    c.tls = empty_tls_conn()
    c.h2 = http2.empty_conn()
    c.host = p.host
    c.port = p.port
    c.open = True
    return c
}

def tls_http_conn(tc: TlsConn, p: @UrlParts) -> HttpConn {
    c = HttpConn()
    c.kind = 1
    c.fd = tc.tcp.fd
    c.tcp = dummy_stream()
    c.tls = tc
    c.h2 = http2.empty_conn()
    c.host = p.host
    c.port = p.port
    c.open = True
    return c
}

def h2_http_conn(hc: H2Conn, p: @UrlParts) -> HttpConn {
    c = HttpConn()
    c.kind = 2
    c.fd = hc.tls.tcp.fd
    c.tcp = dummy_stream()
    c.tls = empty_tls_conn()
    c.h2 = hc
    c.host = p.host
    c.port = p.port
    c.open = True
    return c
}

# Whether a pooled connection can serve p: TLS pool entries (1/2) are interchangeable,
# but when http2 is disabled, connections that negotiated h2 are not reused.
def pool_conn_fits(pc_kind: int, p: @UrlParts, http2_on: bool) -> bool {
    if not p.tls {
        return pc_kind == 0
    }
    if pc_kind == 1 {
        return True
    }
    return pc_kind == 2 and http2_on
}

def request_target(p: @UrlParts) -> str {
    t = p.path
    if p.query.len() > 0 {
        t = t + "?" + p.query
    }
    return t
}

# Connection result after the TLS handshake: upgrades to HTTP/2 when ALPN selected h2.
def tls_conn_result(tr: TlsResult, p: @UrlParts, timeout_ms: int,
                    use_h2: bool) -> ConnResult {
    r = ConnResult()
    r.ok = False
    r.error = ""
    r.conn = empty_conn()
    r.buf = bytes.bytes_new(0)
    r.reused = False
    if use_h2 and tr.conn.get_alpn() == "h2" {
        hr = http2.attach(tr.conn, p.host, p.port)
        if not hr.ok {
            r.error = hr.error
            return r
        }
        hr.conn.tls.tcp.set_timeout(timeout_ms)
        r.conn = h2_http_conn(hr.conn, p)
        r.ok = True
        return r
    }
    tr.conn.tcp.set_timeout(timeout_ms)
    r.conn = tls_http_conn(tr.conn, p)
    r.ok = True
    return r
}

def new_response() -> HttpResponse {
    r = HttpResponse()
    r.status = 0
    r.version = ""
    r.headers = List[str]()
    r.trailers = List[str]()
    r.body = ""
    r.body_bytes = bytes.bytes_new(0)
    r.url = ""
    return r
}

public def fail_result(msg: str) -> HttpResult {
    r = HttpResult()
    r.ok = False
    r.error = msg
    r.response = new_response()
    return r
}

# Parse raw HTTP response text (status line + headers + body).
# The https module reads the complete response streaming and calls this; pure-text splitting, no socket dependency.
public def parse_response(raw: str) -> HttpResult {
    if raw.len() == 0 {
        return fail_result("empty response")
    }
    nl = string.find(raw, "\n")
    if nl < 0 {
        return fail_result("malformed response: no status line")
    }
    status_line = raw.slice(0, nl)
    sl = status_line.len()
    if sl > 0 and status_line.char_at(sl - 1) == 13 {
        status_line = status_line.slice(0, sl - 1)
    }
    sp = string.find(status_line, " ")
    sp2 = string.rfind(status_line, " ")
    if sp < 0 or sp2 <= sp {
        return fail_result("malformed status line")
    }
    code_r = status_line.slice(sp + 1, sp2).to_int()
    if code_r.is_err() {
        return fail_result("malformed status code")
    }
    resp = new_response()
    resp.version = status_line.slice(0, sp)
    resp.status = code_r.unwrap()
    # headers: read line by line until the empty line; the body follows.
    pos = nl + 1
    body_start = -1
    while pos < raw.len() {
        rest = raw.slice(pos, raw.len())
        nl2 = string.find(rest, "\n")
        if nl2 < 0 {
            break
        }
        line = rest.slice(0, nl2)
        pos = pos + nl2 + 1
        ll = line.len()
        if ll > 0 and line.char_at(ll - 1) == 13 {
            line = line.slice(0, ll - 1)
        }
        if line.len() == 0 {
            body_start = pos
            break
        }
        resp.headers.push(line)
    }
    if body_start >= 0 and body_start <= raw.len() {
        resp.body = raw.slice(body_start, raw.len())
    }
    r = HttpResult()
    r.ok = True
    r.error = ""
    r.response = resp
    return r
}

def make_response(ex: Exchange, url: str) -> HttpResponse {
    text = ex.body.to_str()
    resp = HttpResponse()
    resp.status = ex.status
    resp.version = ex.version
    resp.headers = ex.headers
    resp.trailers = ex.trailers
    resp.body = text
    resp.body_bytes = ex.body
    resp.url = url
    return resp
}

public def header(res: @HttpResponse, name: str) -> str {
    return header_in(res.headers, name)
}

public def header_values(res: @HttpResponse, name: str) -> List[str] {
    return header_values_in(res.headers, name)
}

public def trailer(res: @HttpResponse, name: str) -> str {
    return header_in(res.trailers, name)
}

def header_in(headers: @List[str], name: str) -> str {
    want = string.to_lower(name) + ":"
    i = 0
    while i < headers.len() {
        line = headers.get(i)
        lower = string.to_lower(line)
        if lower.startswith(want) {
            return string.trim(line.slice(want.len(), line.len()))
        }
        i = i + 1
    }
    return ""
}

def header_values_in(headers: @List[str], name: str) -> List[str] {
    out = List[str]()
    want = string.to_lower(name) + ":"
    i = 0
    while i < headers.len() {
        line = headers.get(i)
        lower = string.to_lower(line)
        if lower.startswith(want) {
            out.push(string.trim(line.slice(want.len(), line.len())))
        }
        i = i + 1
    }
    return out
}

def has_header(headers: @List[str], name: str) -> bool {
    want = string.to_lower(name) + ":"
    i = 0
    while i < headers.len() {
        if string.to_lower(headers.get(i)).startswith(want) {
            return True
        }
        i = i + 1
    }
    return False
}

def strip_header(headers: @List[str], name: str) -> List[str] {
    out = List[str]()
    want = string.to_lower(name) + ":"
    i = 0
    while i < headers.len() {
        if not string.to_lower(headers.get(i)).startswith(want) {
            out.push(headers.get(i))
        }
        i = i + 1
    }
    return out
}

def valid_header_line(line: str) -> bool {
    colon = string.find(line, ":")
    if colon <= 0 {
        return False
    }
    name = line.slice(0, colon)
    k = 0
    while k < name.len() {
        if not is_token_char(name.char_at(k)) {
            return False
        }
        k = k + 1
    }
    v = line.slice(colon + 1, line.len())
    k = 0
    while k < v.len() {
        c = v.char_at(k)
        if c == 10 or c == 13 or c == 0 {
            return False
        }
        k = k + 1
    }
    return True
}

def validate_headers(headers: @List[str]) -> bool {
    i = 0
    while i < headers.len() {
        if not valid_header_line(headers.get(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def valid_method(m: str) -> bool {
    if m.len() == 0 {
        return False
    }
    i = 0
    while i < m.len() {
        if not is_token_char(m.char_at(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def is_token_char(c: int) -> bool {
    if c >= 65 and c <= 90 {
        return True
    }
    if c >= 97 and c <= 122 {
        return True
    }
    if c >= 48 and c <= 57 {
        return True
    }
    if c == 33 or c == 35 or c == 36 or c == 37 or c == 38 or c == 39 {
        return True
    }
    if c == 42 or c == 43 or c == 45 or c == 46 {
        return True
    }
    return c == 94 or c == 95 or c == 96 or c == 124 or c == 126
}

# ---------------------------------------------------------------------------
# Response header parsing
# ---------------------------------------------------------------------------

def read_head(reader: @var StreamReader) -> HeadResult {
    h = HeadResult()
    h.ok = False
    h.error = ""
    h.version = ""
    h.status = 0
    h.headers = List[str]()
    total = 0
    while True {
        line = reader.read_line()
        if reader.err.len() > 0 {
            h.error = reader.err
            return h
        }
        if line.len() == 0 {
            if not reader.line_complete {
                if total == 0 {
                    h.error = "empty response"
                } else {
                    h.error = "malformed HTTP response"
                }
            } elif total == 0 {
                h.error = "empty response"
            } else {
                h.error = "malformed HTTP response"
            }
            return h
        }
        total = total + line.len() + 2
        if total > reader.max_header {
            h.error = "response header too large"
            return h
        }
        parts = string.split_whitespace(line)
        if parts.len() < 2 {
            h.error = "malformed status line"
            return h
        }
        version = parts.get(0)
        if not version.startswith("HTTP/") {
            h.error = "malformed status line"
            return h
        }
        sr = parts.get(1).to_int()
        if sr.is_err() {
            h.error = "malformed status code"
            return h
        }
        status = sr.unwrap()
        headers = List[str]()
        while True {
            hl = reader.read_line()
            if reader.err.len() > 0 {
                h.error = reader.err
                return h
            }
            if not reader.line_complete {
                h.error = "malformed HTTP response"
                return h
            }
            if hl.len() == 0 {
                break
            }
            total = total + hl.len() + 2
            if total > reader.max_header {
                h.error = "response header too large"
                return h
            }
            headers.push(hl)
        }
        if status >= 100 and status < 200 and status != 101 {
            total = 0
            continue
        }
        h.ok = True
        h.version = version
        h.status = status
        h.headers = headers
        return h
    }
}

def is_redirect(status: int) -> bool {
    return status == 301 or status == 302 or status == 303 or
           status == 307 or status == 308
}

def redirect_makes_get(status: int, method: str) -> bool {
    if method == "HEAD" {
        return False
    }
    if status == 303 {
        return True
    }
    if (status == 301 or status == 302) and method == "POST" {
        return True
    }
    return False
}

def is_retryable(method: str) -> bool {
    return method == "GET" or method == "HEAD" or method == "PUT" or
           method == "DELETE" or method == "OPTIONS" or method == "TRACE"
}

def hex_digit(c: int) -> int {
    if c >= 48 and c <= 57 {
        return c - 48
    }
    if c >= 97 and c <= 102 {
        return c - 87
    }
    if c >= 65 and c <= 70 {
        return c - 55
    }
    return -1
}

def hex_to_int(s: str) -> int {
    if s.len() == 0 {
        return -1
    }
    out = 0
    i = 0
    while i < s.len() {
        d = hex_digit(s.char_at(i))
        if d < 0 {
            return -1
        }
        out = out * 16 + d
        i = i + 1
    }
    return out
}

# ---------------------------------------------------------------------------
# URL
# ---------------------------------------------------------------------------

def url_chars_ok(s: str) -> bool {
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c <= 32 or c == 127 {
            return False
        }
        i = i + 1
    }
    return True
}

def find_first(s: str, a: str, b: str) -> int {
    ia = string.find(s, a)
    ib = string.find(s, b)
    if ia < 0 {
        return ib
    }
    if ib < 0 {
        return ia
    }
    if ia < ib {
        return ia
    }
    return ib
}

public def parse_url(url: str) -> UrlParts {
    p = UrlParts()
    p.ok = False
    p.error = ""
    p.scheme = ""
    p.host = ""
    p.port = 80
    p.authority = ""
    p.path = "/"
    p.query = ""
    p.userinfo = ""
    p.tls = False

    if url.len() == 0 {
        p.error = "URL is empty"
        return p
    }
    if not url_chars_ok(url) {
        p.error = "invalid URL"
        return p
    }
    raw = url
    hash_i = string.find(url, "#")
    if hash_i >= 0 {
        raw = url.slice(0, hash_i)
    }

    lower = string.to_lower(raw)
    rest = ""
    if lower.startswith("https://") {
        p.tls = True
        p.scheme = "https"
        p.port = 443
        rest = raw.slice(8, raw.len())
    } elif lower.startswith("http://") {
        p.scheme = "http"
        p.port = 80
        rest = raw.slice(7, raw.len())
    } else {
        p.error = "unsupported URL scheme"
        return p
    }

    sep = find_first(rest, "/", "?")
    authority = rest
    target = ""
    if sep >= 0 {
        authority = rest.slice(0, sep)
        target = rest.slice(sep, rest.len())
    }
    if authority.len() == 0 {
        p.error = "URL has no host"
        return p
    }

    at = string.rfind(authority, "@")
    hostport = authority
    if at >= 0 {
        p.userinfo = authority.slice(0, at)
        hostport = authority.slice(at + 1, authority.len())
        if hostport.len() == 0 {
            p.error = "URL has no host"
            return p
        }
    }
    p.authority = hostport

    host = hostport
    port = p.port
    if hostport.char_at(0) == 91 {   # '['
        close_i = string.find(hostport, "]")
        if close_i < 0 {
            p.error = "invalid URL"
            return p
        }
        host = hostport.slice(1, close_i)
        after = hostport.slice(close_i + 1, hostport.len())
        if after.len() > 0 {
            if after.char_at(0) != 58 {   # ':'
                p.error = "invalid URL"
                return p
            }
            pr = after.slice(1, after.len()).to_int()
            if pr.is_err() {
                p.error = "invalid port"
                return p
            }
            port = pr.unwrap()
            if port < 1 or port > 65535 {
                p.error = "port out of range"
                return p
            }
        }
    } else {
        colon = string.rfind(hostport, ":")
        if colon >= 0 {
            if string.find(hostport, ":") != colon {
                p.error = "invalid URL"
                return p
            }
            host = hostport.slice(0, colon)
            port_text = hostport.slice(colon + 1, hostport.len())
            pr = port_text.to_int()
            if pr.is_err() {
                p.error = "invalid port"
                return p
            }
            port = pr.unwrap()
            if port < 1 or port > 65535 {
                p.error = "port out of range"
                return p
            }
        }
    }
    if host.len() == 0 {
        p.error = "URL has no host"
        return p
    }

    path = "/"
    query = ""
    if target.len() > 0 {
        q = string.find(target, "?")
        if q >= 0 {
            path = target.slice(0, q)
            query = target.slice(q + 1, target.len())
        } else {
            path = target
        }
        if path.len() == 0 {
            path = "/"
        }
    }

    p.host = host
    p.port = port
    p.path = path
    p.query = query
    p.ok = True
    return p
}

def strip_fragment(s: str) -> str {
    i = string.find(s, "#")
    if i >= 0 {
        return s.slice(0, i)
    }
    return s
}

def normalize_path(p: str) -> str {
    q = ""
    path = p
    qi = string.find(p, "?")
    if qi >= 0 {
        q = p.slice(qi, p.len())
        path = p.slice(0, qi)
    }
    parts = path.split("/")
    stack = List[str]()
    for seg in parts {
        if seg.len() == 0 or seg == "." {
            pass
        } elif seg == ".." {
            if stack.len() > 0 {
                stack.pop()
            }
        } else {
            stack.push(seg)
        }
    }
    out = ""
    for seg in stack {
        out = out + "/" + seg
    }
    if out.len() == 0 {
        out = "/"
    }
    if path.endswith("/") and not out.endswith("/") {
        out = out + "/"
    }
    return out + q
}

public def resolve_url(base_url: str, location: str) -> str {
    loc = strip_fragment(location)
    if loc.len() == 0 {
        return base_url
    }
    lower = string.to_lower(loc)
    if lower.startswith("http://") or lower.startswith("https://") {
        return loc
    }
    b = parse_url(base_url)
    if not b.ok {
        return loc
    }
    base = b.scheme + "://" + b.authority
    if loc.startswith("//") {
        return b.scheme + ":" + loc
    }
    if loc.startswith("/") {
        return base + loc
    }
    if loc.startswith("?") {
        return base + b.path + loc
    }
    dir = b.path
    slash = string.rfind(dir, "/")
    if slash >= 0 {
        dir = dir.slice(0, slash + 1)
    } else {
        dir = "/"
    }
    return base + normalize_path(dir + loc)
}

# ---------------------------------------------------------------------------
# Percent encoding / query strings / Base64
# ---------------------------------------------------------------------------

def is_unreserved(c: int) -> bool {
    if c >= 65 and c <= 90 {
        return True
    }
    if c >= 97 and c <= 122 {
        return True
    }
    if c >= 48 and c <= 57 {
        return True
    }
    return c == 45 or c == 46 or c == 95 or c == 126
}

def upper_hex(n: int) -> str {
    if n < 10 {
        return chr(48 + n)
    }
    return chr(55 + n)
}

public def url_encode(s: str) -> str {
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if is_unreserved(c) {
            out = out + chr(c)
        } else {
            out = out + "%" + upper_hex(c / 16) + upper_hex(c % 16)
        }
        i = i + 1
    }
    return out
}

def decode_pct(s: str, plus_space: bool) -> str {
    b = bytes.bytes_new(s.len() + 1)
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if plus_space and c == 43 {   # '+'
            b.push(32)
            i = i + 1
            continue
        }
        if c == 37 and i + 2 < s.len() {   # '%'
            h1 = hex_digit(s.char_at(i + 1))
            h2 = hex_digit(s.char_at(i + 2))
            if h1 >= 0 and h2 >= 0 {
                b.push(h1 * 16 + h2)
                i = i + 3
                continue
            }
        }
        b.push(c)
        i = i + 1
    }
    return b.to_str()
}

public def url_decode(s: str) -> str {
    return decode_pct(s, True)
}

def percent_decode(s: str) -> str {
    return decode_pct(s, False)
}

# pairs is a list of "key=value" (or just "key"); keys and values are encoded separately then joined with &.
public def encode_query(pairs: @List[str]) -> str {
    out = ""
    i = 0
    while i < pairs.len() {
        pair = pairs.get(i)
        eq = string.find(pair, "=")
        key = pair
        val = ""
        if eq >= 0 {
            key = pair.slice(0, eq)
            val = pair.slice(eq + 1, pair.len())
        }
        if out.len() > 0 {
            out = out + "&"
        }
        out = out + url_encode(key) + "=" + url_encode(val)
        i = i + 1
    }
    return out
}

public def decode_query(query: str) -> List[str] {
    out = List[str]()
    if query.len() == 0 {
        return out
    }
    parts = query.split("&")
    for part in parts {
        if part.len() == 0 {
            pass
        } else {
            out.push(url_decode(part))
        }
    }
    return out
}

def b64_encode(s: str) -> str {
    table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    out = ""
    n = s.len()
    i = 0
    while i + 2 < n {
        b0 = s.char_at(i)
        b1 = s.char_at(i + 1)
        b2 = s.char_at(i + 2)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16 + b1 / 16))
        out = out + chr(table.char_at((b1 % 16) * 4 + b2 / 64))
        out = out + chr(table.char_at(b2 % 64))
        i = i + 3
    }
    left = n - i
    if left == 1 {
        b0 = s.char_at(i)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16))
        out = out + "=="
    } elif left == 2 {
        b0 = s.char_at(i)
        b1 = s.char_at(i + 1)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16 + b1 / 16))
        out = out + chr(table.char_at((b1 % 16) * 4))
        out = out + "="
    }
    return out
}

# ---------------------------------------------------------------------------
# Cookie
# ---------------------------------------------------------------------------

def default_cookie_path(path: str) -> str {
    slash = string.rfind(path, "/")
    if slash <= 0 {
        return "/"
    }
    return path.slice(0, slash)
}

def cookie_token_ok(s: str) -> bool {
    if s.len() == 0 {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c <= 32 or c == 127 or c == 59 or c == 61 or c == 44 {
            return False
        }
        i = i + 1
    }
    return True
}

def cookie_value_ok(s: str) -> bool {
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c < 32 or c == 127 or c == 59 {
            return False
        }
        i = i + 1
    }
    return True
}

def cookie_domain_ok(host: str, c: @HttpCookie) -> bool {
    h = string.to_lower(host)
    d = string.to_lower(c.domain)
    if d.len() == 0 {
        return False
    }
    if c.host_only {
        return h == d
    }
    if h == d {
        return True
    }
    return h.endswith("." + d)
}

def cookie_matches(c: @HttpCookie, p: @UrlParts) -> bool {
    if c.secure and not p.tls {
        return False
    }
    if not cookie_domain_ok(p.host, c) {
        return False
    }
    path = c.path
    if path.len() == 0 {
        path = "/"
    }
    return p.path.startswith(path)
}

def parse_set_cookie(value: str, p: @UrlParts) -> HttpCookie {
    c = HttpCookie()
    c.name = ""
    c.value = ""
    c.domain = string.to_lower(p.host)
    c.path = default_cookie_path(p.path)
    c.secure = False
    c.host_only = True
    c.max_age = -1

    parts = value.split(";")
    if parts.len() == 0 {
        return c
    }
    first = string.trim(parts.get(0))
    eq = string.find(first, "=")
    if eq <= 0 {
        return c
    }
    name = string.trim(first.slice(0, eq))
    val = string.trim(first.slice(eq + 1, first.len()))
    if not cookie_token_ok(name) or not cookie_value_ok(val) {
        return c
    }
    c.name = name
    c.value = val

    i = 1
    while i < parts.len() {
        attr = string.trim(parts.get(i))
        eq2 = string.find(attr, "=")
        aname = attr
        aval = ""
        if eq2 >= 0 {
            aname = string.trim(attr.slice(0, eq2))
            aval = string.trim(attr.slice(eq2 + 1, attr.len()))
        }
        low = string.to_lower(aname)
        if low == "domain" and aval.len() > 0 {
            d = string.to_lower(aval)
            if d.char_at(0) == 46 {
                d = d.slice(1, d.len())
            }
            if d.len() > 0 {
                c.domain = d
                c.host_only = False
            }
            pass
        } elif low == "path" and aval.len() > 0 {
            if aval.char_at(0) == 47 {
                c.path = aval
            }
            pass
        } elif low == "secure" {
            c.secure = True
            pass
        } elif low == "max-age" {
            pr = aval.to_int()
            if not pr.is_err() {
                c.max_age = pr.unwrap()
            }
            pass
        }
        i = i + 1
    }
    return c
}

# ---------------------------------------------------------------------------
# Proxy
# ---------------------------------------------------------------------------

class ProxyParts {
    ok: bool
    error: str
    host: str
    port: int
    auth: str
}

def parse_proxy(proxy: str) -> ProxyParts {
    r = ProxyParts()
    r.ok = False
    r.error = ""
    r.host = ""
    r.port = 80
    r.auth = ""
    text = string.trim(proxy)
    if text.len() == 0 {
        return r
    }
    lower = string.to_lower(text)
    if lower.startswith("https://") {
        r.error = "https proxy is not supported"
        return r
    }
    if lower.startswith("http://") {
        text = text.slice(7, text.len())
    }
    if not url_chars_ok(text) or text.contains("/") or text.contains("?") or text.contains("#") {
        r.error = "invalid proxy address"
        return r
    }
    userinfo = ""
    at = string.rfind(text, "@")
    if at >= 0 {
        userinfo = text.slice(0, at)
        text = text.slice(at + 1, text.len())
    }
    u = parse_url("http://" + text + "/")
    if not u.ok {
        r.error = "invalid proxy address"
        return r
    }
    r.host = u.host
    r.port = u.port
    r.auth = ""
    if userinfo.len() > 0 {
        r.auth = "Basic " + b64_encode(percent_decode(userinfo))
    }
    r.ok = True
    return r
}

# CONNECT tunnel: fd is a socket already connected to the proxy; when successful, the tunnel can carry TLS.
def proxy_connect(fd: int, host: str, port: int, auth: str, max_header: int) -> TunnelResult {
    r = TunnelResult()
    r.ok = False
    r.error = ""
    target = host
    if host.contains(":") {
        target = "[" + host + "]"
    }
    target = target + ":" + to_string(port)
    req = "CONNECT " + target + " HTTP/1.1\r\nHost: " + target + "\r\n"
    if auth.len() > 0 {
        req = req + "Proxy-Authorization: " + auth + "\r\n"
    }
    req = req + "\r\n"

    s = dummy_stream()
    s.fd = fd
    sent = s.send(req)
    if sent < req.len() {
        r.error = "proxy connect failed"
        return r
    }
    tmp = HttpConn()
    tmp.kind = 0
    tmp.fd = fd
    tmp.tcp = s
    tmp.tls = empty_tls_conn()
    tmp.host = host
    tmp.port = port
    tmp.open = True

    reader = StreamReader()
    reader.conn = tmp
    reader.buf = bytes.bytes_new(0)
    reader.eof = False
    reader.err = ""
    reader.line_complete = False
    reader.max_header = max_header
    reader.trailers = List[str]()
    hr = read_head(reader)
    if not hr.ok {
        r.error = "proxy: " + hr.error
        return r
    }
    if hr.status < 200 or hr.status >= 300 {
        r.error = "proxy CONNECT failed with status " + to_string(hr.status)
        return r
    }
    r.ok = True
    return r
}

# ---------------------------------------------------------------------------
# Module-level convenience entries (one-shot connections)
# ---------------------------------------------------------------------------

public def get(url: str) -> HttpResult {
    c = one_shot_client()
    r = c.get(url)
    c.close()
    return r
}

public def get_with(url: str, headers: List[str]) -> HttpResult {
    c = one_shot_client()
    r = c.get_with(url, headers)
    c.close()
    return r
}

public def post(url: str, body: str) -> HttpResult {
    c = one_shot_client()
    r = c.post(url, body)
    c.close()
    return r
}

public def post_with(url: str, body: str, headers: List[str]) -> HttpResult {
    c = one_shot_client()
    r = c.post_with(url, body, headers)
    c.close()
    return r
}

public def request(method: str, url: str, body: str) -> HttpResult {
    c = one_shot_client()
    r = c.request(method, url, body)
    c.close()
    return r
}

public def request_with(method: str, url: str, body: str, headers: List[str]) -> HttpResult {
    c = one_shot_client()
    r = c.request_with(method, url, body, headers)
    c.close()
    return r
}

public def request_bytes(method: str, url: str, body: @Bytes,
                         headers: List[str]) -> HttpResult {
    c = one_shot_client()
    r = c.request_bytes(method, url, body, headers)
    c.close()
    return r
}

# ---------------------------------------------------------------------------
# Async wrapper: one task per thread; the underlying calls are still blocking; use asyncio.gather for concurrency.
# ---------------------------------------------------------------------------

public async def get_async(url: str) -> HttpResult {
    return get(url)
}

public async def post_async(url: str, body: str) -> HttpResult {
    return post(url, body)
}

public async def request_async(method: str, url: str, body: str) -> HttpResult {
    return request(method, url, body)
}
