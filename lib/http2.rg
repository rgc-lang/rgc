# RGC standard library: http2
#
# Synchronous HTTP/2 client (RFC 9113, TLS + ALPN "h2").
# Implements the frame layer, HPACK (static/dynamic tables, Huffman decoding; encoding uses non-indexed literals),
# SETTINGS, WINDOW_UPDATE flow control, HEADERS/CONTINUATION, DATA, trailers,
# PING/GOAWAY/RST_STREAM.
#
# Limitations:
#   - request sends/receives one stream sequentially; get_many multiplexes concurrently over one connection, but GET only;
#   - server push is disabled (SETTINGS_ENABLE_PUSH=0); PUSH_PROMISE frames are rejected outright;
#   - TLS ALPN only; h2c cleartext upgrade/prior-knowledge is unsupported.
#
# It is normally used through the http client (automatic ALPN negotiation; falls back to HTTP/1.1 when h2 is not selected).

import tls
import bytes
import string
import net

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

public class H2Field {
    name: str
    value: str
}

public class H2HeaderList {
    ok: bool
    error: str
    fields: List[H2Field]
    size: int
}

public class H2Huffman {
    lengths: List[int]
    counts: List[int]
    first_code: List[int]
    first_index: List[int]
    symbols: List[int]
}

public class H2Decoder {
    huff: H2Huffman
    static_fields: List[H2Field]
    dynamic: List[H2Field]
    sizes: List[int]
    total: int
    max_size: int
    limit: int
}

public class H2Frame {
    ok: bool
    error: str
    typ: int
    flags: int
    sid: int
    payload: Bytes
}

public class H2Conn {
    tls: TlsConn
    host: str
    port: int
    closed: bool
    goaway: bool
    goaway_last: int
    buf: Bytes
    eof: bool
    next_sid: int
    peer_conn_window: int
    peer_init_window: int
    peer_max_frame: int
    peer_max_streams: int
    active_sid: int
    active_window: int
    dec: H2Decoder

    def close(self) {
        if not self.closed {
            self.tls.close()
        }
        self.closed = True
    }
}

public class H2ConnectResult {
    ok: bool
    error: str
    conn: H2Conn
}

public class H2Response {
    ok: bool
    error: str
    status: int
    headers: List[str]
    trailers: List[str]
    body: Bytes
    conn_closed: bool
}

# Concurrent multiplexing result: responses are in the same order as the requests.
# ok means the transport layer finished overall; a single stream failure (RST/over-limit) only shows in that response's ok.
public class H2MultiResult {
    ok: bool
    error: str
    responses: List[H2Response]
}

class H2StreamState {
    sid: int
    path: str
    sent: bool
    got: bool
    trailer_mode: bool
    status: int
    headers: List[str]
    trailer_lines: List[str]
    body: Bytes
    done: bool
    failed: bool
    error: str
}

class H2Int {
    ok: bool
    error: str
    value: int
    pos: int
}

class H2Str {
    ok: bool
    error: str
    value: str
}

class H2StrPos {
    ok: bool
    error: str
    value: str
    pos: int
}

class H2Name {
    ok: bool
    error: str
    name: str
    pos: int
}

class H2Ctl {
    handled: bool
    ok: bool
    error: str
}

class H2Send {
    ok: bool
    error: str
}

class H2BytesRes {
    ok: bool
    error: str
    data: Bytes
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

def put16(b: @Bytes, v: int) {
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

def put32(b: @Bytes, v: int) {
    b.push((v >> 24) & 255)
    b.push((v >> 16) & 255)
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

def get32(p: @Bytes, off: int) -> int {
    v = (p.get(off) << 24) | (p.get(off + 1) << 16) | (p.get(off + 2) << 8) | p.get(off + 3)
    return v & 2147483647
}

def new_h2_response() -> H2Response {
    r = H2Response()
    r.ok = False
    r.error = ""
    r.status = 0
    r.headers = List[str]()
    r.trailers = List[str]()
    r.body = bytes.bytes_new(0)
    r.conn_closed = False
    return r
}

def new_header_list() -> H2HeaderList {
    r = H2HeaderList()
    r.ok = False
    r.error = ""
    r.fields = List[H2Field]()
    r.size = 0
    return r
}

def new_ctl() -> H2Ctl {
    r = H2Ctl()
    r.handled = False
    r.ok = True
    r.error = ""
    return r
}

def new_frame() -> H2Frame {
    f = H2Frame()
    f.ok = False
    f.error = ""
    f.typ = 0
    f.flags = 0
    f.sid = 0
    f.payload = bytes.bytes_new(0)
    return f
}

# ---------------------------------------------------------------------------
# HPACK static table and Huffman code lengths (RFC 7541)
# ---------------------------------------------------------------------------

def sf(n: str, v: str) -> H2Field {
    f = H2Field()
    f.name = n
    f.value = v
    return f
}

def static_table() -> List[H2Field] {
    t = List[H2Field]()
    t.push(sf(":authority", ""))
    t.push(sf(":method", "GET"))
    t.push(sf(":method", "POST"))
    t.push(sf(":path", "/"))
    t.push(sf(":path", "/index.html"))
    t.push(sf(":scheme", "http"))
    t.push(sf(":scheme", "https"))
    t.push(sf(":status", "200"))
    t.push(sf(":status", "204"))
    t.push(sf(":status", "206"))
    t.push(sf(":status", "304"))
    t.push(sf(":status", "400"))
    t.push(sf(":status", "404"))
    t.push(sf(":status", "500"))
    t.push(sf("accept-charset", ""))
    t.push(sf("accept-encoding", "gzip, deflate"))
    t.push(sf("accept-language", ""))
    t.push(sf("accept-ranges", ""))
    t.push(sf("accept", ""))
    t.push(sf("access-control-allow-origin", ""))
    t.push(sf("age", ""))
    t.push(sf("allow", ""))
    t.push(sf("authorization", ""))
    t.push(sf("cache-control", ""))
    t.push(sf("content-disposition", ""))
    t.push(sf("content-encoding", ""))
    t.push(sf("content-language", ""))
    t.push(sf("content-length", ""))
    t.push(sf("content-location", ""))
    t.push(sf("content-range", ""))
    t.push(sf("content-type", ""))
    t.push(sf("cookie", ""))
    t.push(sf("date", ""))
    t.push(sf("etag", ""))
    t.push(sf("expect", ""))
    t.push(sf("expires", ""))
    t.push(sf("from", ""))
    t.push(sf("host", ""))
    t.push(sf("if-match", ""))
    t.push(sf("if-modified-since", ""))
    t.push(sf("if-none-match", ""))
    t.push(sf("if-range", ""))
    t.push(sf("if-unmodified-since", ""))
    t.push(sf("last-modified", ""))
    t.push(sf("link", ""))
    t.push(sf("location", ""))
    t.push(sf("max-forwards", ""))
    t.push(sf("proxy-authenticate", ""))
    t.push(sf("proxy-authorization", ""))
    t.push(sf("range", ""))
    t.push(sf("referer", ""))
    t.push(sf("refresh", ""))
    t.push(sf("retry-after", ""))
    t.push(sf("server", ""))
    t.push(sf("set-cookie", ""))
    t.push(sf("strict-transport-security", ""))
    t.push(sf("transfer-encoding", ""))
    t.push(sf("user-agent", ""))
    t.push(sf("vary", ""))
    t.push(sf("via", ""))
    t.push(sf("www-authenticate", ""))
    return t
}

def new_huffman() -> H2Huffman {
    h = H2Huffman()
    h.lengths = List[int]()
    # The 257 code lengths are encoded as printable chars via (length + 50): '7' means 5 bits, 'P' means 30 bits.
    enc = "?INNNNNNNJPNNPNNNNNNNNPNNNNNNNNN8<<>?8:=<<:=:88877788888889:A8><?89999999999999999999999:9:?E?@8A787" +
        "87888799888789877899999A=@?NFHFFHHHIHIIIIIJIJJHIJIIIIGHIHIIJHGFHHIIGIHHJGHIIGGHGIHIIFHHHIHHILLFEHIHK" +
        "LLLMMLJKEGLMMLMJGGLLNMMMFJFGHGGIHHKKJJLILMLLMMMMMNMMMMMLP"
    i = 0
    while i < enc.len() {
        h.lengths.push(enc.char_at(i) - 50)
        i = i + 1
    }

    i = 0
    while i <= 30 {
        h.counts.push(0)
        i = i + 1
    }
    i = 0
    while i < h.lengths.len() {
        n = h.lengths.get(i)
        if n > 0 {
            h.counts.set(n, h.counts.get(n) + 1)
        }
        i = i + 1
    }

    h.first_code = List[int]()
    h.first_index = List[int]()
    i = 0
    while i <= 30 {
        h.first_code.push(0)
        h.first_index.push(0)
        i = i + 1
    }
    code = 0
    idx = 0
    L = 1
    while L <= 30 {
        h.first_code.set(L, code)
        h.first_index.set(L, idx)
        code = (code + h.counts.get(L)) << 1
        idx = idx + h.counts.get(L)
        L = L + 1
    }

    h.symbols = List[int]()
    L = 1
    while L <= 30 {
        s = 0
        while s <= 256 {
            if h.lengths.get(s) == L {
                h.symbols.push(s)
            }
            s = s + 1
        }
        L = L + 1
    }
    return h
}

public def new_decoder() -> H2Decoder {
    d = H2Decoder()
    d.huff = new_huffman()
    d.static_fields = static_table()
    d.dynamic = List[H2Field]()
    d.sizes = List[int]()
    d.total = 0
    d.max_size = 4096
    d.limit = 4096
    return d
}

# ---------------------------------------------------------------------------
# HPACK dynamic table
# ---------------------------------------------------------------------------

def table_evict_one(d: @var H2Decoder) -> bool {
    if d.dynamic.len() == 0 {
        return False
    }
    nd = List[H2Field]()
    ns = List[int]()
    i = 1
    while i < d.dynamic.len() {
        nd.push(d.dynamic.get(i))
        ns.push(d.sizes.get(i))
        i = i + 1
    }
    d.total = d.total - d.sizes.get(0)
    if d.total < 0 {
        d.total = 0
    }
    d.dynamic = nd
    d.sizes = ns
    return True
}

def table_add(d: @var H2Decoder, name: str, value: str) {
    sz = name.len() + value.len() + 32
    while d.total + sz > d.max_size and d.dynamic.len() > 0 {
        if not table_evict_one(d) {
            break
        }
    }
    if sz > d.max_size {
        d.dynamic = List[H2Field]()
        d.sizes = List[int]()
        d.total = 0
        return
    }
    f = H2Field()
    f.name = name
    f.value = value
    d.dynamic.push(f)
    d.sizes.push(sz)
    d.total = d.total + sz
}

def table_has(d: @H2Decoder, idx: int) -> bool {
    if idx >= 1 and idx <= 61 {
        return True
    }
    k = idx - 62
    return k >= 0 and k < d.dynamic.len()
}

def table_lookup(d: @H2Decoder, idx: int) -> H2Field {
    if idx >= 1 and idx <= 61 {
        return d.static_fields.get(idx - 1)
    }
    k = idx - 62
    pos = d.dynamic.len() - 1 - k
    if pos >= 0 and pos < d.dynamic.len() {
        return d.dynamic.get(pos)
    }
    return sf("", "")
}

# ---------------------------------------------------------------------------
# HPACK decoding
# ---------------------------------------------------------------------------

def dec_int(b: @Bytes, pos: int, prefix: int) -> H2Int {
    r = H2Int()
    r.ok = False
    r.error = ""
    r.value = 0
    r.pos = pos
    if pos < 0 or pos >= b.len {
        r.error = "truncated integer"
        return r
    }
    mask = (1 << prefix) - 1
    v = b.get(pos) & mask
    p = pos + 1
    if v < mask {
        r.ok = True
        r.value = v
        r.pos = p
        return r
    }
    m = 0
    while True {
        if p >= b.len {
            r.error = "truncated integer"
            return r
        }
        byte = b.get(p)
        p = p + 1
        v = v + ((byte & 127) << m)
        m = m + 7
        if (byte & 128) == 0 {
            break
        }
        if m > 28 {
            r.error = "integer too large"
            return r
        }
    }
    if v > 2147483647 {
        r.error = "integer too large"
        return r
    }
    r.ok = True
    r.value = v
    r.pos = p
    return r
}

def huff_decode(h: @H2Huffman, src: @Bytes, start: int, n: int) -> H2Str {
    r = H2Str()
    r.ok = False
    r.error = ""
    r.value = ""
    out = bytes.bytes_new(n + 8)
    code = 0
    clen = 0
    i = 0
    while i < n {
        byte = src.get(start + i)
        bit = 7
        while bit >= 0 {
            b = (byte >> bit) & 1
            code = (code << 1) | b
            clen = clen + 1
            if clen > 30 {
                r.error = "invalid huffman code"
                return r
            }
            if clen >= 5 {
                cnt = h.counts.get(clen)
                if cnt > 0 {
                    fc = h.first_code.get(clen)
                    if code >= fc and code < fc + cnt {
                        sym = h.symbols.get(h.first_index.get(clen) + (code - fc))
                        if sym == 256 {
                            r.error = "invalid huffman code"
                            return r
                        }
                        out.push(sym)
                        code = 0
                        clen = 0
                    }
                }
            }
            bit = bit - 1
        }
        i = i + 1
    }
    if clen > 7 {
        r.error = "invalid huffman padding"
        return r
    }
    if clen > 0 and code != (1 << clen) - 1 {
        r.error = "invalid huffman padding"
        return r
    }
    if out.has_nul() {
        r.error = "invalid header value"
        return r
    }
    r.ok = True
    r.value = out.to_str()
    return r
}

def dec_str(d: @H2Decoder, b: @Bytes, pos: int, max_len: int) -> H2StrPos {
    r = H2StrPos()
    r.ok = False
    r.error = ""
    r.value = ""
    r.pos = pos
    if pos < 0 or pos >= b.len {
        r.error = "truncated string"
        return r
    }
    huff = (b.get(pos) & 128) != 0
    ir = dec_int(b, pos, 7)
    if not ir.ok {
        r.error = ir.error
        return r
    }
    n = ir.value
    if ir.pos + n > b.len {
        r.error = "truncated string"
        return r
    }
    if max_len > 0 and n > max_len {
        r.error = "header string too large"
        return r
    }
    if huff {
        hs = huff_decode(d.huff, b, ir.pos, n)
        if not hs.ok {
            r.error = hs.error
            return r
        }
        r.value = hs.value
    } else {
        if n > 0 {
            seg = b.slice(ir.pos, ir.pos + n)
            if seg.has_nul() {
                r.error = "invalid header value"
                return r
            }
            r.value = seg.to_str()
        }
    }
    r.pos = ir.pos + n
    r.ok = True
    return r
}

def dec_name(d: @H2Decoder, b: @Bytes, pos: int, prefix: int) -> H2Name {
    r = H2Name()
    r.ok = False
    r.error = ""
    r.name = ""
    r.pos = pos
    ir = dec_int(b, pos, prefix)
    if not ir.ok {
        r.error = ir.error
        return r
    }
    if ir.value == 0 {
        sr = dec_str(d, b, ir.pos, 65536)
        if not sr.ok {
            r.error = sr.error
            return r
        }
        if sr.value.len() == 0 {
            r.error = "empty header name"
            return r
        }
        r.name = sr.value
        r.pos = sr.pos
        r.ok = True
        return r
    }
    if not table_has(d, ir.value) {
        r.error = "invalid header index"
        return r
    }
    f = table_lookup(d, ir.value)
    r.name = f.name
    r.pos = ir.pos
    r.ok = True
    return r
}

def push_field(r: @var H2HeaderList, name: str, value: str) {
    f = H2Field()
    f.name = name
    f.value = value
    r.fields.push(f)
}

public def decode_block(d: @var H2Decoder, block: @Bytes, max_size: int) -> H2HeaderList {
    r = new_header_list()
    pos = 0
    total = 0
    while pos < block.len {
        b0 = block.get(pos)
        if (b0 & 128) != 0 {
            ir = dec_int(block, pos, 7)
            if not ir.ok {
                r.error = ir.error
                return r
            }
            pos = ir.pos
            if ir.value == 0 or not table_has(d, ir.value) {
                r.error = "invalid indexed header"
                return r
            }
            f = table_lookup(d, ir.value)
            total = total + f.name.len() + f.value.len() + 32
            if max_size > 0 and total > max_size {
                r.error = "response header too large"
                return r
            }
            push_field(r, f.name, f.value)
        } elif (b0 & 192) == 64 {
            nm = dec_name(d, block, pos, 6)
            if not nm.ok {
                r.error = nm.error
                return r
            }
            sv = dec_str(d, block, nm.pos, 65536)
            if not sv.ok {
                r.error = sv.error
                return r
            }
            pos = sv.pos
            total = total + nm.name.len() + sv.value.len() + 32
            if max_size > 0 and total > max_size {
                r.error = "response header too large"
                return r
            }
            table_add(d, nm.name, sv.value)
            push_field(r, nm.name, sv.value)
        } elif (b0 & 224) == 32 {
            ir = dec_int(block, pos, 5)
            if not ir.ok {
                r.error = ir.error
                return r
            }
            pos = ir.pos
            if ir.value > d.limit {
                r.error = "invalid dynamic table size"
                return r
            }
            d.max_size = ir.value
            while d.total > d.max_size {
                if not table_evict_one(d) {
                    break
                }
            }
        } else {
            nm = dec_name(d, block, pos, 4)
            if not nm.ok {
                r.error = nm.error
                return r
            }
            sv = dec_str(d, block, nm.pos, 65536)
            if not sv.ok {
                r.error = sv.error
                return r
            }
            pos = sv.pos
            total = total + nm.name.len() + sv.value.len() + 32
            if max_size > 0 and total > max_size {
                r.error = "response header too large"
                return r
            }
            push_field(r, nm.name, sv.value)
        }
    }
    r.size = total
    r.ok = True
    return r
}

# ---------------------------------------------------------------------------
# HPACK encoding (non-indexed literals only; no encoder-side dynamic table is maintained)
# ---------------------------------------------------------------------------

def put_cont(out: @var Bytes, x: int) {
    v = x
    while v >= 128 {
        out.push((v & 127) | 128)
        v = v >> 7
    }
    out.push(v)
}

def put_str(out: @var Bytes, s: str) {
    n = s.len()
    if n < 127 {
        out.push(n)
    } else {
        out.push(127)
        put_cont(out, n - 127)
    }
    out.append_mem(s, n)
}

def static_name_index(st: @List[H2Field], name: str) -> int {
    i = 0
    while i < st.len() {
        if st.get(i).name == name {
            return i + 1
        }
        i = i + 1
    }
    return 0
}

def put_literal(out: @var Bytes, st: @List[H2Field], name: str, value: str) {
    idx = static_name_index(st, name)
    if idx >= 1 and idx < 15 {
        out.push(idx)
    } elif idx >= 15 {
        out.push(15)
        put_cont(out, idx - 15)
    } else {
        out.push(0)
        put_str(out, name)
    }
    put_str(out, value)
}

def skip_header(name: str, value: str) -> bool {
    ln = string.to_lower(name)
    if ln == "connection" or ln == "keep-alive" or ln == "proxy-connection" {
        return True
    }
    if ln == "transfer-encoding" or ln == "upgrade" or ln == "host" {
        return True
    }
    if ln == "te" and string.to_lower(string.trim(value)) != "trailers" {
        return True
    }
    if ln.len() == 0 {
        return True
    }
    return False
}

def put_header_lines(out: @var Bytes, st: @List[H2Field], headers: @List[str]) {
    i = 0
    while i < headers.len() {
        line = headers.get(i)
        colon = string.find(line, ":")
        if colon > 0 {
            name = string.to_lower(string.trim(line.slice(0, colon)))
            value = string.trim(line.slice(colon + 1, line.len()))
            if not skip_header(name, value) {
                put_literal(out, st, name, value)
            }
        }
        i = i + 1
    }
}

public def encode_request_headers(method: str, scheme: str, authority: str, path: str,
                                  headers: @List[str]) -> Bytes {
    out = bytes.bytes_new(256)
    st = static_table()
    put_literal(out, st, ":method", method)
    put_literal(out, st, ":scheme", scheme)
    put_literal(out, st, ":authority", authority)
    put_literal(out, st, ":path", path)
    put_header_lines(out, st, headers)
    return out
}

public def encode_response_headers(status: int, headers: @List[str]) -> Bytes {
    out = bytes.bytes_new(256)
    st = static_table()
    put_literal(out, st, ":status", to_string(status))
    put_header_lines(out, st, headers)
    return out
}

public def encode_trailers(headers: @List[str]) -> Bytes {
    out = bytes.bytes_new(128)
    st = static_table()
    put_header_lines(out, st, headers)
    return out
}

# ---------------------------------------------------------------------------
# Frame layer
# ---------------------------------------------------------------------------

public def encode_frame(typ: int, flags: int, sid: int, payload: @Bytes) -> Bytes {
    out = bytes.bytes_new(9 + payload.len)
    n = payload.len
    out.push((n >> 16) & 255)
    out.push((n >> 8) & 255)
    out.push(n & 255)
    out.push(typ & 255)
    out.push(flags & 255)
    out.push((sid >> 24) & 127)
    out.push((sid >> 16) & 255)
    out.push((sid >> 8) & 255)
    out.push(sid & 255)
    out.append(payload)
    return out
}

def read_into(c: @var H2Conn, need: int) -> H2BytesRes {
    r = H2BytesRes()
    r.ok = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    while c.buf.len < need and not c.eof {
        rr = c.tls.recv_bytes(16384)
        if not rr.ok {
            r.error = rr.error
            return r
        }
        if rr.value.len == 0 {
            c.eof = True
            break
        }
        c.buf.append_mem(rr.value.data, rr.value.len)
    }
    if c.buf.len < need {
        r.error = "connection closed"
        return r
    }
    out = c.buf.slice(0, need)
    c.buf.drop_front(need)
    r.ok = True
    r.data = out
    return r
}

def read_frame(c: @var H2Conn) -> H2Frame {
    r = new_frame()
    hr = read_into(c, 9)
    if not hr.ok {
        r.error = hr.error
        return r
    }
    h = hr.data
    n = (h.get(0) << 16) | (h.get(1) << 8) | h.get(2)
    if n > 16384 {
        c.closed = True
        r.error = "frame too large"
        return r
    }
    r.typ = h.get(3)
    r.flags = h.get(4)
    r.sid = ((h.get(5) & 127) << 24) | (h.get(6) << 16) | (h.get(7) << 8) | h.get(8)
    if n > 0 {
        pr = read_into(c, n)
        if not pr.ok {
            r.error = pr.error
            return r
        }
        r.payload = pr.data
    }
    r.ok = True
    return r
}

def write_frame(c: @var H2Conn, typ: int, flags: int, sid: int, payload: @Bytes) -> bool {
    if c.closed {
        return False
    }
    f = encode_frame(typ, flags, sid, payload)
    n = c.tls.send_mem(f.data, f.len)
    if n < f.len {
        c.closed = True
        return False
    }
    return True
}

def send_window_update(c: @var H2Conn, sid: int, inc: int) -> bool {
    if inc <= 0 {
        return True
    }
    p = bytes.bytes_new(4)
    put32(p, inc)
    return write_frame(c, 8, 0, sid, p)
}

# ---------------------------------------------------------------------------
# Control frames
# ---------------------------------------------------------------------------

def handle_control(c: @var H2Conn, f: @H2Frame, sid: int) -> H2Ctl {
    r = new_ctl()
    if f.typ == 0 or f.typ == 1 or f.typ == 9 {
        return r
    }
    if f.typ == 4 {   # SETTINGS
        r.handled = True
        if (f.flags & 1) != 0 {
            return r
        }
        if f.payload.len % 6 != 0 {
            r.ok = False
            r.error = "malformed SETTINGS"
            return r
        }
        i = 0
        while i < f.payload.len {
            id = (f.payload.get(i) << 8) | f.payload.get(i + 1)
            v = get32(f.payload, i + 2)
            if id == 4 {   # INITIAL_WINDOW_SIZE
                if v > 2147483647 {
                    r.ok = False
                    r.error = "invalid initial window size"
                    return r
                }
                delta = v - c.peer_init_window
                c.peer_init_window = v
                if sid > 0 and c.active_sid == sid {
                    c.active_window = c.active_window + delta
                }
            } elif id == 5 {   # MAX_FRAME_SIZE
                if v < 16384 or v > 16777215 {
                    r.ok = False
                    r.error = "invalid max frame size"
                    return r
                }
                c.peer_max_frame = v
            } elif id == 3 {   # MAX_CONCURRENT_STREAMS
                c.peer_max_streams = v
            }
            i = i + 6
        }
        if not write_frame(c, 4, 1, 0, bytes.bytes_new(0)) {
            r.ok = False
            r.error = "send failed"
        }
        return r
    }
    if f.typ == 6 {   # PING
        r.handled = True
        if (f.flags & 1) != 0 {
            return r
        }
        if f.payload.len != 8 {
            r.ok = False
            r.error = "malformed PING"
            return r
        }
        if not write_frame(c, 6, 1, 0, f.payload) {
            r.ok = False
            r.error = "send failed"
        }
        return r
    }
    if f.typ == 8 {   # WINDOW_UPDATE
        r.handled = True
        if f.payload.len != 4 {
            r.ok = False
            r.error = "malformed WINDOW_UPDATE"
            return r
        }
        inc = get32(f.payload, 0)
        if inc == 0 {
            r.ok = False
            r.error = "invalid window increment"
            return r
        }
        if f.sid == 0 {
            c.peer_conn_window = c.peer_conn_window + inc
            if c.peer_conn_window > 2147483647 {
                c.peer_conn_window = 2147483647
            }
        } elif f.sid == sid {
            c.active_window = c.active_window + inc
            if c.active_window > 2147483647 {
                c.active_window = 2147483647
            }
        }
        return r
    }
    if f.typ == 7 {   # GOAWAY
        r.handled = True
        c.goaway = True
        if f.payload.len >= 8 {
            last = get32(f.payload, 0)
            c.goaway_last = last
            if sid > 0 and last < sid {
                r.ok = False
                r.error = "connection closed by GOAWAY"
            }
        } else {
            c.goaway_last = 0
            if sid > 0 {
                r.ok = False
                r.error = "connection closed by GOAWAY"
            }
        }
        return r
    }
    if f.typ == 3 {   # RST_STREAM
        r.handled = True
        if sid > 0 and f.sid == sid {
            code = 0
            if f.payload.len >= 4 {
                code = get32(f.payload, 0)
            }
            r.ok = False
            r.error = "stream reset by peer (code " + to_string(code) + ")"
        }
        return r
    }
    if f.typ == 5 {   # PUSH_PROMISE: push is disabled, reject
        r.handled = True
        off = 0
        if (f.flags & 8) != 0 {
            off = 1
        }
        if f.payload.len >= off + 4 {
            promised = get32(f.payload, off)
            rp = bytes.bytes_new(4)
            put32(rp, 7)   # REFUSED_STREAM
            write_frame(c, 3, 0, promised, rp)
        }
        return r
    }
    r.handled = True
    return r
}

# ---------------------------------------------------------------------------
# Connection and requests
# ---------------------------------------------------------------------------

def dummy_tcp() -> TcpStream {
    t = TcpStream()
    t.fd = -1
    t.timeout_ms = 0
    return t
}

public def empty_conn() -> H2Conn {
    c = H2Conn()
    tc = TlsConn()
    tc.ssl = ptr_null()
    tc.ctx = ptr_null()
    tc.tcp = dummy_tcp()
    tc.timeout_ms = 0
    tc.alpn = ""
    c.tls = tc
    c.host = ""
    c.port = 0
    c.closed = True
    c.goaway = False
    c.goaway_last = 0
    c.buf = bytes.bytes_new(0)
    c.eof = False
    c.next_sid = 1
    c.peer_conn_window = 65535
    c.peer_init_window = 65535
    c.peer_max_frame = 16384
    c.peer_max_streams = -1
    c.active_sid = 0
    c.active_window = 0
    c.dec = new_decoder()
    return c
}

# Client connection preface + local SETTINGS.
def our_settings() -> Bytes {
    p = bytes.bytes_new(18)
    put16(p, 2)      # SETTINGS_ENABLE_PUSH
    put32(p, 0)
    put16(p, 4)      # SETTINGS_INITIAL_WINDOW_SIZE
    put32(p, 1048576)
    put16(p, 6)      # SETTINGS_MAX_HEADER_LIST_SIZE
    put32(p, 65536)
    return p
}

def send_preface(c: @var H2Conn) -> bool {
    p = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    n = c.tls.send_mem(p, p.len())
    if n < p.len() {
        c.closed = True
        return False
    }
    return True
}

def fail_connect(msg: str) -> H2ConnectResult {
    r = H2ConnectResult()
    r.ok = False
    r.error = msg
    r.conn = empty_conn()
    return r
}

def fail_attached(c: @var H2Conn, msg: str) -> H2ConnectResult {
    c.close()
    return fail_connect(msg)
}

# Send the preface over a completed TLS connection (ALPN selected h2) and wait for the server's SETTINGS.
# Takes ownership of tc; closes the underlying connection on failure.
public def attach(tc: TlsConn, host: str, port: int) -> H2ConnectResult {
    if tc.get_alpn() != "h2" {
        tc.close()
        return fail_connect("HTTP/2 was not negotiated")
    }
    c = empty_conn()
    c.tls = tc
    c.host = host
    c.port = port
    c.closed = False
    c.buf = bytes.bytes_new(0)

    if not send_preface(c) {
        return fail_attached(c, "send failed")
    }
    if not write_frame(c, 4, 0, 0, our_settings()) {
        return fail_attached(c, "send failed")
    }
    if not send_window_update(c, 0, 983041) {
        return fail_attached(c, "send failed")
    }

    fr = read_frame(c)
    if not fr.ok {
        return fail_attached(c, fr.error)
    }
    if fr.typ != 4 or (fr.flags & 1) != 0 {
        return fail_attached(c, "expected server SETTINGS")
    }
    ctl = handle_control(c, fr, 0)
    if not ctl.ok {
        return fail_attached(c, ctl.error)
    }
    r = H2ConnectResult()
    r.ok = True
    r.error = ""
    r.conn = c
    return r
}

# New TCP + TLS (offering ALPN h2) and complete the HTTP/2 handshake.
public def connect(host: str, port: int, timeout_ms: int, verify: bool,
                   ca_file: str, cert_file: str, key_file: str) -> H2ConnectResult {
    tr = tls.connect_alpn(host, port, timeout_ms, verify, ca_file, cert_file, key_file,
                          True)
    if not tr.ok {
        return fail_connect(tr.error)
    }
    if tr.conn.get_alpn() != "h2" {
        tr.conn.close()
        return fail_connect("HTTP/2 was not negotiated")
    }
    return attach(tr.conn, host, port)
}

def send_header_block(c: @var H2Conn, sid: int, block: @Bytes, end_stream: bool) -> bool {
    off = 0
    first = True
    while first or off < block.len {
        n = block.len - off
        if n > c.peer_max_frame {
            n = c.peer_max_frame
        }
        chunk = block.slice(off, off + n)
        flags = 0
        if first and end_stream {
            flags = flags | 1
        }
        if off + n >= block.len {
            flags = flags | 4
        }
        typ = 1
        if not first {
            typ = 9
        }
        if not write_frame(c, typ, flags, sid, chunk) {
            return False
        }
        first = False
        off = off + n
    }
    return True
}

def send_data(c: @var H2Conn, sid: int, ptr: str, n: int) -> H2Send {
    r = H2Send()
    r.ok = True
    r.error = ""
    off = 0
    while off < n {
        guard = 0
        while c.peer_conn_window <= 0 or c.active_window <= 0 {
            fr = read_frame(c)
            if not fr.ok {
                c.closed = True
                r.ok = False
                r.error = fr.error
                return r
            }
            ctl = handle_control(c, fr, sid)
            if not ctl.ok {
                c.closed = True
                r.ok = False
                r.error = ctl.error
                return r
            }
            if not ctl.handled {
                c.closed = True
                r.ok = False
                r.error = "unexpected response while sending request body"
                return r
            }
            guard = guard + 1
            if guard > 1000000 {
                c.closed = True
                r.ok = False
                r.error = "flow control stalled"
                return r
            }
        }
        k = n - off
        if k > c.peer_max_frame {
            k = c.peer_max_frame
        }
        if k > c.peer_conn_window {
            k = c.peer_conn_window
        }
        if k > c.active_window {
            k = c.active_window
        }
        chunk = bytes.bytes_from_mem(int_to_ptr(ptr_to_int(ptr) + off), k)
        flags = 0
        if off + k >= n {
            flags = 1
        }
        if not write_frame(c, 0, flags, sid, chunk) {
            c.closed = True
            r.ok = False
            r.error = "send failed"
            return r
        }
        off = off + k
        c.peer_conn_window = c.peer_conn_window - k
        c.active_window = c.active_window - k
    }
    return r
}

def read_header_block(c: @var H2Conn, f: @H2Frame, max_header: int) -> H2HeaderList {
    r = new_header_list()
    p = f.payload
    start = 0
    end = p.len
    if (f.flags & 8) != 0 {
        if p.len < 1 {
            r.error = "malformed padded HEADERS"
            return r
        }
        pad = p.get(0)
        start = 1
        if start + pad > end {
            r.error = "malformed padded HEADERS"
            return r
        }
        end = end - pad
    }
    if (f.flags & 32) != 0 {
        start = start + 5
        if start > end {
            r.error = "malformed HEADERS priority"
            return r
        }
    }
    block = bytes.bytes_new(end - start + 64)
    if end > start {
        block.append_mem(int_to_ptr(ptr_to_int(p.data) + start), end - start)
    }
    cap = max_header * 2 + 1024
    if max_header <= 0 {
        cap = 1048576
    }
    if block.len > cap {
        r.error = "response header too large"
        return r
    }
    done = (f.flags & 4) != 0
    while not done {
        nf = read_frame(c)
        if not nf.ok {
            r.error = nf.error
            return r
        }
        if nf.typ != 9 or nf.sid != f.sid {
            r.error = "malformed CONTINUATION"
            return r
        }
        if block.len + nf.payload.len > cap {
            r.error = "response header too large"
            return r
        }
        block.append(nf.payload)
        if (nf.flags & 4) != 0 {
            done = True
        }
    }
    return decode_block(c.dec, block, max_header)
}

def find_status(hl: @H2HeaderList) -> int {
    i = 0
    while i < hl.fields.len() {
        f = hl.fields.get(i)
        if f.name == ":status" {
            pr = f.value.to_int()
            if pr.is_err() {
                return -1
            }
            return pr.unwrap()
        }
        i = i + 1
    }
    return -1
}

def has_pseudo(hl: @H2HeaderList) -> bool {
    i = 0
    while i < hl.fields.len() {
        if hl.fields.get(i).name.startswith(":") {
            return True
        }
        i = i + 1
    }
    return False
}

def lines_from_fields(hl: @H2HeaderList) -> List[str] {
    out = List[str]()
    i = 0
    while i < hl.fields.len() {
        f = hl.fields.get(i)
        if not f.name.startswith(":") {
            out.push(f.name + ": " + f.value)
        }
        i = i + 1
    }
    return out
}

def recv_response(c: @var H2Conn, sid: int, max_header: int, max_body: int) -> H2Response {
    r = new_h2_response()
    got = False
    trailers = False
    body = bytes.bytes_new(256)
    done = False
    while not done {
        fr = read_frame(c)
        if not fr.ok {
            c.closed = True
            r.error = fr.error
            r.conn_closed = True
            return r
        }
        ctl = handle_control(c, fr, sid)
        if not ctl.ok {
            c.closed = True
            r.error = ctl.error
            r.conn_closed = True
            return r
        }
        if ctl.handled {
            pass
        } elif fr.sid != sid {
            if fr.typ == 0 {
                send_window_update(c, 0, fr.payload.len)
            }
        } elif fr.typ == 1 {
            if trailers {
                c.closed = True
                r.error = "unexpected HEADERS after trailers"
                r.conn_closed = True
                return r
            }
            hl = read_header_block(c, fr, max_header)
            if not hl.ok {
                c.closed = True
                r.error = hl.error
                r.conn_closed = True
                return r
            }
            if not got {
                st = find_status(hl)
                if st < 0 {
                    c.closed = True
                    r.error = "missing :status"
                    r.conn_closed = True
                    return r
                }
                if st >= 100 and st < 200 {
                    pass
                } else {
                    r.status = st
                    r.headers = lines_from_fields(hl)
                    got = True
                    if (fr.flags & 1) != 0 {
                        done = True
                    }
                }
            } else {
                if has_pseudo(hl) {
                    c.closed = True
                    r.error = "pseudo header in trailers"
                    r.conn_closed = True
                    return r
                }
                r.trailers = lines_from_fields(hl)
                trailers = True
                if (fr.flags & 1) != 0 {
                    done = True
                }
            }
        } elif fr.typ == 0 {
            if not got {
                c.closed = True
                r.error = "response DATA before HEADERS"
                r.conn_closed = True
                return r
            }
            if trailers {
                c.closed = True
                r.error = "response DATA after trailers"
                r.conn_closed = True
                return r
            }
            p = fr.payload
            start = 0
            end = p.len
            if (fr.flags & 8) != 0 {
                if p.len < 1 {
                    c.closed = True
                    r.error = "malformed padded DATA"
                    r.conn_closed = True
                    return r
                }
                pad = p.get(0)
                start = 1
                if start + pad > end {
                    c.closed = True
                    r.error = "malformed padded DATA"
                    r.conn_closed = True
                    return r
                }
                end = end - pad
            }
            seglen = end - start
            if max_body > 0 and body.len + seglen > max_body {
                rp = bytes.bytes_new(4)
                put32(rp, 8)   # CANCEL
                write_frame(c, 3, 0, sid, rp)
                r.error = "response body too large"
                return r
            }
            if seglen > 0 {
                body.append_mem(int_to_ptr(ptr_to_int(p.data) + start), seglen)
            }
            if fr.payload.len > 0 {
                if not send_window_update(c, 0, fr.payload.len) {
                    c.closed = True
                    r.error = "send failed"
                    r.conn_closed = True
                    return r
                }
                if not send_window_update(c, sid, fr.payload.len) {
                    c.closed = True
                    r.error = "send failed"
                    r.conn_closed = True
                    return r
                }
            }
            if (fr.flags & 1) != 0 {
                done = True
            }
        } elif fr.typ == 9 {
            c.closed = True
            r.error = "unexpected CONTINUATION"
            r.conn_closed = True
            return r
        } else {
            pass
        }
    }
    r.ok = True
    r.body = body
    r.conn_closed = c.closed or c.goaway or c.eof
    return r
}

# Send one request and read the complete response. headers are "name: value" lines (no pseudo-headers).
public def request(c: @var H2Conn, method: str, scheme: str, authority: str, path: str,
                   headers: List[str], body_ptr: str, body_len: int, has_body: bool,
                   max_header: int, max_body: int) -> H2Response {
    r = new_h2_response()
    if c.closed or c.goaway {
        r.error = "HTTP/2 connection is closed"
        r.conn_closed = True
        return r
    }
    sid = c.next_sid
    c.next_sid = c.next_sid + 2
    c.active_sid = sid
    c.active_window = c.peer_init_window

    block = encode_request_headers(method, scheme, authority, path, headers)
    end_stream = not has_body or body_len == 0
    if not send_header_block(c, sid, block, end_stream) {
        c.active_sid = 0
        c.closed = True
        r.error = "send failed"
        r.conn_closed = True
        return r
    }
    if has_body and body_len > 0 {
        sr = send_data(c, sid, body_ptr, body_len)
        if not sr.ok {
            c.active_sid = 0
            r.error = sr.error
            r.conn_closed = True
            return r
        }
    }
    rr = recv_response(c, sid, max_header, max_body)
    c.active_sid = 0
    return rr
}

# ---------------------------------------------------------------------------
# Concurrent multiplexing (GET only)
# ---------------------------------------------------------------------------

def new_multi_result() -> H2MultiResult {
    r = H2MultiResult()
    r.ok = False
    r.error = ""
    r.responses = List[H2Response]()
    return r
}

def new_stream_state(path: str) -> H2StreamState {
    st = H2StreamState()
    st.sid = 0
    st.path = path
    st.sent = False
    st.got = False
    st.trailer_mode = False
    st.status = 0
    st.headers = List[str]()
    st.trailer_lines = List[str]()
    st.body = bytes.bytes_new(256)
    st.done = False
    st.failed = False
    st.error = ""
    return st
}

def find_stream(states: @List[H2StreamState], sid: int) -> int {
    i = 0
    while i < states.len() {
        if states.get(i).sid == sid {
            return i
        }
        i = i + 1
    }
    return -1
}

# Send multiple GETs concurrently over one HTTP/2 connection and collect the responses (multiplexing).
# Response order matches paths; the server's MAX_CONCURRENT_STREAMS is respected and excess requests queue.
# A single stream RST or max_body overflow only fails that stream; the rest continue.
# headers are "name: value" lines (no pseudo-headers), applied to every request.
public def get_many(c: @var H2Conn, scheme: str, authority: str, paths: List[str],
                    headers: List[str], max_header: int, max_body: int) -> H2MultiResult {
    r = new_multi_result()
    n = paths.len()
    if c.closed or c.goaway {
        r.error = "HTTP/2 connection is closed"
        i = 0
        while i < n {
            rr = new_h2_response()
            rr.error = r.error
            rr.conn_closed = True
            r.responses.push(rr)
            i = i + 1
        }
        return r
    }
    if n == 0 {
        r.ok = True
        return r
    }

    states = List[H2StreamState]()
    i = 0
    while i < n {
        states.push(new_stream_state(paths.get(i)))
        i = i + 1
    }

    next_send = 0
    open = 0
    remaining = n
    conn_error = ""
    c.active_sid = 0
    c.active_window = 0

    while remaining > 0 {
        while next_send < n and not c.closed and not c.goaway {
            if c.peer_max_streams >= 0 and open >= c.peer_max_streams {
                break
            }
            st = states.get(next_send)
            sid = c.next_sid
            c.next_sid = c.next_sid + 2
            st.sid = sid
            block = encode_request_headers("GET", scheme, authority, st.path, headers)
            if not send_header_block(c, sid, block, True) {
                c.closed = True
                conn_error = "send failed"
                break
            }
            st.sent = True
            states.set(next_send, st)
            next_send = next_send + 1
            open = open + 1
        }
        if conn_error.len() > 0 {
            break
        }
        if next_send >= n and open <= 0 {
            break
        }
        if c.closed {
            conn_error = "connection closed"
            break
        }
        if c.goaway and open <= 0 {
            break
        }

        fr = read_frame(c)
        if not fr.ok {
            c.closed = True
            conn_error = fr.error
            break
        }
        ctl = handle_control(c, fr, 0)
        if not ctl.ok {
            c.closed = True
            conn_error = ctl.error
            break
        }
        if ctl.handled {
            if fr.typ == 3 {   # RST_STREAM: only terminates the corresponding stream
                idx = find_stream(states, fr.sid)
                if idx >= 0 {
                    st = states.get(idx)
                    if st.sent and not st.done and not st.failed {
                        code = 0
                        if fr.payload.len >= 4 {
                            code = get32(fr.payload, 0)
                        }
                        st.failed = True
                        st.error = "stream reset by peer (code " + to_string(code) + ")"
                        states.set(idx, st)
                        open = open - 1
                        remaining = remaining - 1
                    }
                }
            }
            if c.goaway {
                # Streams the server did not process (including ones not yet sent) fail outright; already-sent ones finish gracefully.
                j = 0
                while j < n {
                    st = states.get(j)
                    if st.failed or st.done {
                        pass
                    } elif not st.sent {
                        st.failed = True
                        st.error = "connection closed by GOAWAY"
                        states.set(j, st)
                        remaining = remaining - 1
                    } elif st.sid > c.goaway_last {
                        st.failed = True
                        st.error = "connection closed by GOAWAY"
                        states.set(j, st)
                        open = open - 1
                        remaining = remaining - 1
                    }
                    j = j + 1
                }
                next_send = n
            }
            continue
        }

        idx = find_stream(states, fr.sid)
        if idx < 0 {
            if fr.typ == 0 and fr.payload.len > 0 {
                send_window_update(c, 0, fr.payload.len)
            }
            continue
        }
        st = states.get(idx)
        if st.done or st.failed {
            # Cancelled streams may still receive in-flight DATA; the connection window must be replenished.
            if fr.typ == 0 and fr.payload.len > 0 {
                send_window_update(c, 0, fr.payload.len)
            }
            continue
        }

        if fr.typ == 1 {   # HEADERS / trailers
            if st.trailer_mode {
                c.closed = True
                conn_error = "unexpected HEADERS after trailers"
                break
            }
            hl = read_header_block(c, fr, max_header)
            if not hl.ok {
                c.closed = True
                conn_error = hl.error
                break
            }
            if not st.got {
                stt = find_status(hl)
                if stt < 0 {
                    c.closed = True
                    conn_error = "missing :status"
                    break
                }
                if stt >= 100 and stt < 200 {
                    pass
                } else {
                    st.status = stt
                    st.headers = lines_from_fields(hl)
                    st.got = True
                    if (fr.flags & 1) != 0 {
                        st.done = True
                    }
                }
            } else {
                if has_pseudo(hl) {
                    c.closed = True
                    conn_error = "pseudo header in trailers"
                    break
                }
                st.trailer_lines = lines_from_fields(hl)
                st.trailer_mode = True
                if (fr.flags & 1) != 0 {
                    st.done = True
                }
            }
        } elif fr.typ == 0 {   # DATA
            if not st.got {
                c.closed = True
                conn_error = "response DATA before HEADERS"
                break
            }
            if st.trailer_mode {
                c.closed = True
                conn_error = "response DATA after trailers"
                break
            }
            p = fr.payload
            start = 0
            end = p.len
            if (fr.flags & 8) != 0 {
                if p.len < 1 {
                    c.closed = True
                    conn_error = "malformed padded DATA"
                    break
                }
                pad = p.get(0)
                start = 1
                if start + pad > end {
                    c.closed = True
                    conn_error = "malformed padded DATA"
                    break
                }
                end = end - pad
            }
            seglen = end - start
            if max_body > 0 and st.body.len + seglen > max_body {
                rp = bytes.bytes_new(4)
                put32(rp, 8)   # CANCEL
                write_frame(c, 3, 0, st.sid, rp)
                if fr.payload.len > 0 {
                    send_window_update(c, 0, fr.payload.len)
                }
                st.failed = True
                st.error = "response body too large"
                states.set(idx, st)
                open = open - 1
                remaining = remaining - 1
                continue
            }
            if seglen > 0 {
                st.body.append_mem(int_to_ptr(ptr_to_int(p.data) + start), seglen)
            }
            if fr.payload.len > 0 {
                if not send_window_update(c, 0, fr.payload.len) {
                    c.closed = True
                    conn_error = "send failed"
                    break
                }
                if not send_window_update(c, st.sid, fr.payload.len) {
                    c.closed = True
                    conn_error = "send failed"
                    break
                }
            }
            if (fr.flags & 1) != 0 {
                st.done = True
            }
        } elif fr.typ == 9 {
            c.closed = True
            conn_error = "unexpected CONTINUATION"
            break
        }

        states.set(idx, st)
        if st.done {
            open = open - 1
            remaining = remaining - 1
        }
    }

    if conn_error.len() > 0 {
        r.error = conn_error
    } else {
        r.ok = True
    }
    i = 0
    while i < n {
        st = states.get(i)
        rr = new_h2_response()
        rr.status = st.status
        rr.headers = st.headers
        rr.trailers = st.trailer_lines
        rr.body = st.body
        rr.conn_closed = c.closed or c.goaway or c.eof
        if st.done {
            rr.ok = True
        } else {
            rr.ok = False
            if st.error.len() > 0 {
                rr.error = st.error
            } elif conn_error.len() > 0 {
                rr.error = conn_error
            } else {
                rr.error = "response incomplete"
            }
        }
        r.responses.push(rr)
        i = i + 1
    }
    return r
}
