# RGC standard library: gzip
#
# Pure RGC implementation of DEFLATE (RFC 1951) with gzip (RFC 1952) and zlib (RFC 1950)
# containers. No external zlib dependency: the codec, CRC-32 and Adler-32 are all RGC.
#
# Usage:
#   import gzip
#   r = gzip.decompress(@compressed)
#   if r.ok { print(r.data.len) } else { print(r.error) }
#
#   # limit output size (anti-zip-bomb)
#   r = gzip.decompress_limit(@compressed, 1048576)
#
#   # compress into a gzip container
#   c = gzip.compress(@plain)
#   if c.ok { print(c.data.len) }
#
# Notes:
#   - Input/output are bytes.Bytes (binary safe); decompress_mem accepts a raw pointer + length.
#   - Auto-detects gzip (1f 8b) and zlib headers; anything else is tried as raw deflate;
#     multiple gzip members are concatenated automatically.
#   - Decompression supports stored, fixed-Huffman and dynamic-Huffman blocks and verifies
#     CRC-32 / ISIZE (gzip) and Adler-32 (zlib).
#   - Compression emits a single fixed-Huffman LZ77 block (level 0 uses stored blocks);
#     the result is a standard gzip stream readable by zlib/gzip/Python.
#   - GzipResult.members is the member count during decompression (1 on successful compression).

import bytes

public class GzipResult {
    ok: bool
    error: str
    data: Bytes
    members: int
}

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------

def crc32_mem(p: str, n: int) -> int {
    crc = 4294967295
    i = 0
    while i < n {
        crc = crc ^ buf_get8(p, i)
        k = 0
        while k < 8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 3988292384
            } else {
                crc = crc >> 1
            }
            k = k + 1
        }
        i = i + 1
    }
    return crc ^ 4294967295
}

def adler32_mem(p: str, n: int) -> int {
    s1 = 1
    s2 = 0
    i = 0
    while i < n {
        s1 = s1 + buf_get8(p, i)
        if s1 >= 65521 {
            s1 = s1 - 65521
        }
        s2 = s2 + s1
        if s2 >= 65521 {
            s2 = s2 - 65521
        }
        i = i + 1
    }
    return (s2 << 16) | s1
}

# ---------------------------------------------------------------------------
# Huffman trees (canonical, puff-style decode)
# ---------------------------------------------------------------------------

class Tree {
    count: List[int]   # count[len] = number of codes of this length
    sym: List[int]     # symbols ordered by (length, symbol)
    left: int          # 0 = complete or empty; > 0 = incomplete; < 0 = over-subscribed
}

def empty_tree() -> Tree {
    t = Tree()
    t.count = List[int]()
    t.sym = List[int]()
    t.left = 0
    return t
}

def tree_build(lengths: @List[int], n: int) -> Tree {
    t = empty_tree()
    i = 0
    while i <= 15 {
        t.count.push(0)
        i = i + 1
    }
    i = 0
    while i < n {
        l = lengths.get(i)
        t.count.set(l, t.count.get(l) + 1)
        i = i + 1
    }
    if t.count.get(0) == n {
        return t
    }
    left = 1
    L = 1
    while L <= 15 {
        left = (left << 1) - t.count.get(L)
        if left < 0 {
            t.left = left
            return t
        }
        L = L + 1
    }
    t.left = left
    i = 0
    while i < n {
        t.sym.push(0)
        i = i + 1
    }
    offs = List[int]()
    i = 0
    while i <= 15 {
        offs.push(0)
        i = i + 1
    }
    L = 1
    while L < 15 {
        offs.set(L + 1, offs.get(L) + t.count.get(L))
        L = L + 1
    }
    i = 0
    while i < n {
        l = lengths.get(i)
        if l != 0 {
            t.sym.set(offs.get(l), i)
            offs.set(l, offs.get(l) + 1)
        }
        i = i + 1
    }
    return t
}

# ---------------------------------------------------------------------------
# Inflater
# ---------------------------------------------------------------------------

class Inflate {
    p: str
    n: int
    pos: int
    bitbuf: int
    bitcnt: int
    out: Bytes
    limit: int     # -1 = unlimited, >= 0 = max output bytes
    err: str
    lt: Tree
    dt: Tree
    ct: Tree
    lb: List[int]
    le: List[int]
    db: List[int]
    de: List[int]

    def init(self, p: str, n: int, start: int, limit: int) {
        self.p = p
        self.n = n
        self.pos = start
        self.bitbuf = 0
        self.bitcnt = 0
        self.out = bytes.bytes_new(n)
        self.limit = limit
        self.err = ""
        self.lt = empty_tree()
        self.dt = empty_tree()
        self.ct = empty_tree()
        self.lb = List[int]()
        self.le = List[int]()
        self.db = List[int]()
        self.de = List[int]()
        i = 0
        while i < 29 {
            self.lb.push(length_base(i))
            self.le.push(length_extra(i))
            i = i + 1
        }
        i = 0
        while i < 30 {
            self.db.push(dist_base(i))
            self.de.push(dist_extra(i))
            i = i + 1
        }
    }

    def bits(self, need: int) -> int {
        while self.bitcnt < need {
            if self.pos >= self.n {
                self.err = "truncated compressed data"
                return 0
            }
            self.bitbuf = self.bitbuf | (buf_get8(self.p, self.pos) << self.bitcnt)
            self.pos = self.pos + 1
            self.bitcnt = self.bitcnt + 8
        }
        v = self.bitbuf & ((1 << need) - 1)
        self.bitbuf = self.bitbuf >> need
        self.bitcnt = self.bitcnt - need
        return v
    }

    def align(self) {
        self.bitbuf = 0
        self.bitcnt = 0
    }

    def u8(self) -> int {
        if self.pos >= self.n {
            self.err = "truncated compressed data"
            return 0
        }
        v = buf_get8(self.p, self.pos)
        self.pos = self.pos + 1
        return v
    }

    def u16le(self) -> int {
        a = self.u8()
        b = self.u8()
        return a | (b << 8)
    }

    def u32le(self) -> int {
        a = self.u8()
        b = self.u8()
        c = self.u8()
        d = self.u8()
        return a | (b << 8) | (c << 16) | (d << 24)
    }

    def u32be(self) -> int {
        a = self.u8()
        b = self.u8()
        c = self.u8()
        d = self.u8()
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    def decode_lit(self) -> int {
        code = 0
        first = 0
        index = 0
        L = 1
        while L <= 15 {
            code = code | self.bits(1)
            cnt = self.lt.count.get(L)
            if code - cnt < first {
                return self.lt.sym.get(index + (code - first))
            }
            index = index + cnt
            first = first + cnt
            first = first << 1
            code = code << 1
            L = L + 1
        }
        self.err = "invalid literal/length code"
        return -1
    }

    def decode_dist(self) -> int {
        code = 0
        first = 0
        index = 0
        L = 1
        while L <= 15 {
            code = code | self.bits(1)
            cnt = self.dt.count.get(L)
            if code - cnt < first {
                return self.dt.sym.get(index + (code - first))
            }
            index = index + cnt
            first = first + cnt
            first = first << 1
            code = code << 1
            L = L + 1
        }
        self.err = "invalid distance code"
        return -1
    }

    def decode_clen(self) -> int {
        code = 0
        first = 0
        index = 0
        L = 1
        while L <= 15 {
            code = code | self.bits(1)
            cnt = self.ct.count.get(L)
            if code - cnt < first {
                return self.ct.sym.get(index + (code - first))
            }
            index = index + cnt
            first = first + cnt
            first = first << 1
            code = code << 1
            L = L + 1
        }
        self.err = "invalid code lengths set"
        return -1
    }

    def fixed_trees(self) {
        lens = List[int]()
        i = 0
        while i < 288 {
            if i < 144 {
                lens.push(8)
            } elif i < 256 {
                lens.push(9)
            } elif i < 280 {
                lens.push(7)
            } else {
                lens.push(8)
            }
            i = i + 1
        }
        self.lt = tree_build(lens, 288)
        dl = List[int]()
        i = 0
        while i < 32 {
            dl.push(5)
            i = i + 1
        }
        self.dt = tree_build(dl, 32)
    }

    def stored_block(self) -> bool {
        self.align()
        if self.pos + 4 > self.n {
            self.err = "truncated compressed data"
            return False
        }
        blen = self.u16le()
        nlen = self.u16le()
        if self.err.len() > 0 {
            return False
        }
        if (blen ^ 65535) != nlen {
            self.err = "invalid stored block lengths"
            return False
        }
        if self.pos + blen > self.n {
            self.err = "truncated compressed data"
            return False
        }
        if self.limit >= 0 and self.out.len + blen > self.limit {
            self.err = "output limit exceeded"
            return False
        }
        if blen > 0 {
            self.out.append_mem(int_to_ptr(ptr_to_int(self.p) + self.pos), blen)
            self.pos = self.pos + blen
        }
        return True
    }

    def dynamic_trees(self) -> bool {
        hlit = self.bits(5) + 257
        hdist = self.bits(5) + 1
        hclen = self.bits(4) + 4
        if self.err.len() > 0 {
            return False
        }
        if hlit > 286 or hdist > 30 {
            self.err = "invalid code lengths set"
            return False
        }
        order = List[int]()
        order.push(16)
        order.push(17)
        order.push(18)
        order.push(0)
        order.push(8)
        order.push(7)
        order.push(9)
        order.push(6)
        order.push(10)
        order.push(5)
        order.push(11)
        order.push(4)
        order.push(12)
        order.push(3)
        order.push(13)
        order.push(2)
        order.push(14)
        order.push(1)
        order.push(15)
        cl = List[int]()
        i = 0
        while i < 19 {
            cl.push(0)
            i = i + 1
        }
        k = 0
        while k < hclen {
            cl.set(order.get(k), self.bits(3))
            k = k + 1
        }
        if self.err.len() > 0 {
            return False
        }
        self.ct = tree_build(cl, 19)
        if self.ct.left < 0 {
            self.err = "invalid code lengths set"
            return False
        }

        total = hlit + hdist
        lens = List[int]()
        i = 0
        while i < total {
            lens.push(0)
            i = i + 1
        }
        i = 0
        prev = 0
        while i < total {
            sym = self.decode_clen()
            if self.err.len() > 0 {
                return False
            }
            if sym < 16 {
                lens.set(i, sym)
                prev = sym
                i = i + 1
            } elif sym == 16 {
                if i == 0 {
                    self.err = "invalid bit length repeat"
                    return False
                }
                r = self.bits(2) + 3
                if self.err.len() > 0 {
                    return False
                }
                while r > 0 and i < total {
                    lens.set(i, prev)
                    i = i + 1
                    r = r - 1
                }
                if r > 0 {
                    self.err = "invalid bit length repeat"
                    return False
                }
            } elif sym == 17 {
                r = self.bits(3) + 3
                if self.err.len() > 0 {
                    return False
                }
                while r > 0 and i < total {
                    lens.set(i, 0)
                    i = i + 1
                    r = r - 1
                }
                if r > 0 {
                    self.err = "invalid bit length repeat"
                    return False
                }
                prev = 0
            } else {
                r = self.bits(7) + 11
                if self.err.len() > 0 {
                    return False
                }
                while r > 0 and i < total {
                    lens.set(i, 0)
                    i = i + 1
                    r = r - 1
                }
                if r > 0 {
                    self.err = "invalid bit length repeat"
                    return False
                }
                prev = 0
            }
        }

        lit_lens = List[int]()
        i = 0
        while i < hlit {
            lit_lens.push(lens.get(i))
            i = i + 1
        }
        dist_lens = List[int]()
        while i < total {
            dist_lens.push(lens.get(i))
            i = i + 1
        }
        self.lt = tree_build(lit_lens, hlit)
        if self.lt.left < 0 {
            self.err = "invalid literal/lengths set"
            return False
        }
        if self.lt.left > 0 and hlit != self.lt.count.get(0) + self.lt.count.get(1) {
            self.err = "invalid literal/lengths set"
            return False
        }
        self.dt = tree_build(dist_lens, hdist)
        if self.dt.left < 0 {
            self.err = "invalid distances set"
            return False
        }
        if self.dt.left > 0 and hdist != self.dt.count.get(0) + self.dt.count.get(1) {
            self.err = "invalid distances set"
            return False
        }
        return True
    }

    def codes_block(self) -> bool {
        while True {
            sym = self.decode_lit()
            if self.err.len() > 0 {
                return False
            }
            if sym < 256 {
                if self.limit >= 0 and self.out.len + 1 > self.limit {
                    self.err = "output limit exceeded"
                    return False
                }
                self.out.push(sym)
            } elif sym == 256 {
                return True
            } else {
                if sym > 285 {
                    self.err = "invalid literal/length code"
                    return False
                }
                k = sym - 257
                length = self.lb.get(k) + self.bits(self.le.get(k))
                if self.err.len() > 0 {
                    return False
                }
                ds = self.decode_dist()
                if self.err.len() > 0 {
                    return False
                }
                if ds > 29 {
                    self.err = "invalid distance code"
                    return False
                }
                distance = self.db.get(ds) + self.bits(self.de.get(ds))
                if self.err.len() > 0 {
                    return False
                }
                if distance > self.out.len {
                    self.err = "invalid distance too far back"
                    return False
                }
                if self.limit >= 0 and self.out.len + length > self.limit {
                    self.err = "output limit exceeded"
                    return False
                }
                i = 0
                while i < length {
                    self.out.push(buf_get8(self.out.data, self.out.len - distance))
                    i = i + 1
                }
            }
        }
        return True
    }

    # Inflate all blocks of one deflate stream. Returns False and sets err on failure.
    def stream(self) -> bool {
        final = 0
        while final == 0 {
            final = self.bits(1)
            if self.err.len() > 0 {
                return False
            }
            typ = self.bits(2)
            if self.err.len() > 0 {
                return False
            }
            if typ == 0 {
                if not self.stored_block() {
                    return False
                }
            } elif typ == 1 {
                self.fixed_trees()
                if not self.codes_block() {
                    return False
                }
            } elif typ == 2 {
                if not self.dynamic_trees() {
                    return False
                }
                if not self.codes_block() {
                    return False
                }
            } else {
                self.err = "invalid block type"
                return False
            }
        }
        return True
    }
}

# Length / distance code tables (RFC 1951 section 3.2.5).
def length_base(k: int) -> int {
    if k < 8 {
        return 3 + k
    }
    if k == 8 {
        return 11
    }
    if k < 12 {
        return 11 + 2 * (k - 8)
    }
    if k < 16 {
        return 19 + 4 * (k - 12)
    }
    if k < 20 {
        return 35 + 8 * (k - 16)
    }
    if k < 24 {
        return 67 + 16 * (k - 20)
    }
    if k < 28 {
        return 131 + 32 * (k - 24)
    }
    return 258
}

def length_extra(k: int) -> int {
    if k < 8 {
        return 0
    }
    if k == 28 {
        return 0
    }
    if k < 12 {
        return 1
    }
    if k < 16 {
        return 2
    }
    if k < 20 {
        return 3
    }
    if k < 24 {
        return 4
    }
    return 5
}

def dist_base(k: int) -> int {
    if k < 4 {
        return 1 + k
    }
    if k < 6 {
        return 5 + 2 * (k - 4)
    }
    if k < 8 {
        return 9 + 4 * (k - 6)
    }
    if k < 10 {
        return 17 + 8 * (k - 8)
    }
    if k < 12 {
        return 33 + 16 * (k - 10)
    }
    if k < 14 {
        return 65 + 32 * (k - 12)
    }
    if k < 16 {
        return 129 + 64 * (k - 14)
    }
    if k < 18 {
        return 257 + 128 * (k - 16)
    }
    if k < 20 {
        return 513 + 256 * (k - 18)
    }
    if k < 22 {
        return 1025 + 512 * (k - 20)
    }
    if k < 24 {
        return 2049 + 1024 * (k - 22)
    }
    if k < 26 {
        return 4097 + 2048 * (k - 24)
    }
    if k < 28 {
        return 8193 + 4096 * (k - 26)
    }
    return 16385 + 8192 * (k - 28)
}

def dist_extra(k: int) -> int {
    if k < 4 {
        return 0
    }
    if k < 6 {
        return 1
    }
    if k < 8 {
        return 2
    }
    if k < 10 {
        return 3
    }
    if k < 12 {
        return 4
    }
    if k < 14 {
        return 5
    }
    if k < 16 {
        return 6
    }
    if k < 18 {
        return 7
    }
    if k < 20 {
        return 8
    }
    if k < 22 {
        return 9
    }
    if k < 24 {
        return 10
    }
    if k < 26 {
        return 11
    }
    if k < 28 {
        return 12
    }
    return 13
}

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

class GzHead {
    ok: bool
    error: str
    pos: int
}

def new_head() -> GzHead {
    h = GzHead()
    h.ok = False
    h.error = ""
    h.pos = 0
    return h
}

def gzip_header(src: @Bytes, start: int) -> GzHead {
    h = new_head()
    if start + 10 > src.len {
        h.error = "truncated compressed data"
        return h
    }
    if src.get(start) != 31 or src.get(start + 1) != 139 {
        h.error = "incorrect header check"
        return h
    }
    if src.get(start + 2) != 8 {
        h.error = "unknown compression method"
        return h
    }
    flg = src.get(start + 3)
    if flg & 224 != 0 {
        h.error = "unknown header flags set"
        return h
    }
    p = start + 10
    if flg & 4 != 0 {
        if p + 2 > src.len {
            h.error = "truncated compressed data"
            return h
        }
        xlen = src.get(p) | (src.get(p + 1) << 8)
        p = p + 2 + xlen
        if p > src.len {
            h.error = "truncated compressed data"
            return h
        }
    }
    if flg & 8 != 0 {
        while p < src.len and src.get(p) != 0 {
            p = p + 1
        }
        if p >= src.len {
            h.error = "truncated compressed data"
            return h
        }
        p = p + 1
    }
    if flg & 16 != 0 {
        while p < src.len and src.get(p) != 0 {
            p = p + 1
        }
        if p >= src.len {
            h.error = "truncated compressed data"
            return h
        }
        p = p + 1
    }
    if flg & 2 != 0 {
        if p + 2 > src.len {
            h.error = "truncated compressed data"
            return h
        }
        want = src.get(p) | (src.get(p + 1) << 8)
        header_crc = crc32_mem(int_to_ptr(ptr_to_int(src.data) + start), p - start) & 65535
        if header_crc != want {
            h.error = "header crc mismatch"
            return h
        }
        p = p + 2
    }
    h.pos = p
    h.ok = True
    return h
}

def zlib_header(src: @Bytes, start: int) -> GzHead {
    h = new_head()
    if start + 2 > src.len {
        h.error = "truncated compressed data"
        return h
    }
    cmf = src.get(start)
    flg = src.get(start + 1)
    if (cmf * 256 + flg) % 31 != 0 {
        h.error = "incorrect header check"
        return h
    }
    if cmf & 15 != 8 {
        h.error = "unknown compression method"
        return h
    }
    if (cmf >> 4) > 7 {
        h.error = "invalid window size"
        return h
    }
    p = start + 2
    if flg & 32 != 0 {
        h.error = "preset dictionary not supported"
        return h
    }
    h.pos = p
    h.ok = True
    return h
}

def new_result() -> GzipResult {
    r = GzipResult()
    r.ok = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    r.members = 0
    return r
}

def gzip_inflate(src: @Bytes, limit: int) -> GzipResult {
    r = new_result()
    lim = limit
    if lim <= 0 {
        lim = -1
    }
    total = bytes.bytes_new(src.len + 64)
    pos = 0
    members = 0
    while True {
        h = gzip_header(src, pos)
        if not h.ok {
            r.error = h.error
            return r
        }
        rem = -1
        if lim > 0 {
            rem = lim - total.len
            if rem < 0 {
                rem = 0
            }
        }
        inf = Inflate()
        inf.init(src.data, src.len, h.pos, rem)
        if not inf.stream() {
            r.error = inf.err
            return r
        }
        inf.align()
        tp = inf.pos
        if tp + 8 > src.len {
            r.error = "truncated compressed data"
            return r
        }
        want_crc = src.get(tp) | (src.get(tp + 1) << 8) | (src.get(tp + 2) << 16) |
                   (src.get(tp + 3) << 24)
        want_len = src.get(tp + 4) | (src.get(tp + 5) << 8) | (src.get(tp + 6) << 16) |
                   (src.get(tp + 7) << 24)
        if crc32_mem(inf.out.data, inf.out.len) != want_crc {
            r.error = "incorrect data check"
            return r
        }
        if (inf.out.len & 4294967295) != want_len {
            r.error = "incorrect length check"
            return r
        }
        total.append_mem(inf.out.data, inf.out.len)
        members = members + 1
        pos = tp + 8
        if pos + 2 > src.len or src.get(pos) != 31 or src.get(pos + 1) != 139 {
            break
        }
    }
    r.data = total
    r.members = members
    r.ok = True
    return r
}

def zlib_inflate(src: @Bytes, limit: int) -> GzipResult {
    r = new_result()
    lim = limit
    if lim <= 0 {
        lim = -1
    }
    h = zlib_header(src, 0)
    if not h.ok {
        r.error = h.error
        return r
    }
    inf = Inflate()
    inf.init(src.data, src.len, h.pos, lim)
    if not inf.stream() {
        r.error = inf.err
        return r
    }
    inf.align()
    tp = inf.pos
    if tp + 4 > src.len {
        r.error = "truncated compressed data"
        return r
    }
    want = (src.get(tp) << 24) | (src.get(tp + 1) << 16) | (src.get(tp + 2) << 8) |
           src.get(tp + 3)
    if adler32_mem(inf.out.data, inf.out.len) != want {
        r.error = "incorrect data check"
        return r
    }
    r.data = inf.out
    r.members = 1
    r.ok = True
    return r
}

def raw_inflate(src: @Bytes, limit: int) -> GzipResult {
    r = new_result()
    lim = limit
    if lim <= 0 {
        lim = -1
    }
    inf = Inflate()
    inf.init(src.data, src.len, 0, lim)
    if not inf.stream() {
        r.error = inf.err
        return r
    }
    r.data = inf.out
    r.members = 1
    r.ok = True
    return r
}

def auto_inflate(src: @Bytes, limit: int) -> GzipResult {
    if src.len == 0 {
        r = new_result()
        r.error = "empty compressed data"
        return r
    }
    if is_gzip(src) {
        return gzip_inflate(src, limit)
    }
    if is_zlib(src) {
        return zlib_inflate(src, limit)
    }
    r = new_result()
    r.error = "incorrect header check"
    return r
}

# Decompress gzip/zlib; on failure retry as raw deflate (some servers omit the container header).
public def decompress(src: @Bytes) -> GzipResult {
    r = auto_inflate(src, 0)
    if r.ok {
        return r
    }
    r2 = raw_inflate(src, 0)
    if r2.ok {
        return r2
    }
    return r
}

# Same as decompress, but fails when the output exceeds limit bytes (anti-zip-bomb); limit <= 0 means unlimited.
public def decompress_limit(src: @Bytes, limit: int) -> GzipResult {
    lim = limit
    if lim <= 0 {
        lim = -1
    }
    r = auto_inflate(src, lim)
    if r.ok {
        return r
    }
    r2 = raw_inflate(src, lim)
    if r2.ok {
        return r2
    }
    if r2.error == "output limit exceeded" {
        return r2
    }
    return r
}

public def is_gzip(src: @Bytes) -> bool {
    if src.len < 2 {
        return False
    }
    return src.get(0) == 31 and src.get(1) == 139
}

public def is_zlib(src: @Bytes) -> bool {
    if src.len < 2 {
        return False
    }
    b0 = src.get(0)
    b1 = src.get(1)
    if b0 % 16 != 8 {
        return False
    }
    return (b0 * 256 + b1) % 31 == 0
}

# Convenience entry: pass a memory buffer directly (from FFI or Bytes.data).
public def decompress_mem(p: str, n: int) -> GzipResult {
    b = bytes.bytes_from_mem(p, n)
    return decompress(@b)
}

# ---------------------------------------------------------------------------
# Deflater: LZ77 with fixed Huffman codes (level 0 = stored blocks)
# ---------------------------------------------------------------------------

class Deflater {
    out: Bytes
    bitbuf: int
    bitcnt: int
    head: List[int]
    prev: List[int]

    def init(self) {
        self.out = bytes.bytes_new(256)
        self.bitbuf = 0
        self.bitcnt = 0
        self.head = List[int]()
        self.prev = List[int]()
    }

    def put_raw(self, v: int, n: int) {
        self.bitbuf = self.bitbuf | ((v & ((1 << n) - 1)) << self.bitcnt)
        self.bitcnt = self.bitcnt + n
        while self.bitcnt >= 8 {
            self.out.push(self.bitbuf & 255)
            self.bitbuf = self.bitbuf >> 8
            self.bitcnt = self.bitcnt - 8
        }
    }

    # Huffman codes are sent most-significant bit first; the bit stream is LSB-first.
    def put_code(self, code: int, n: int) {
        rev = 0
        i = 0
        while i < n {
            rev = (rev << 1) | ((code >> i) & 1)
            i = i + 1
        }
        self.put_raw(rev, n)
    }

    def align(self) {
        if self.bitcnt > 0 {
            self.out.push(self.bitbuf & 255)
            self.bitbuf = 0
            self.bitcnt = 0
        }
    }

    def emit_lit(self, sym: int) {
        if sym < 144 {
            self.put_code(48 + sym, 8)
        } elif sym < 256 {
            self.put_code(400 + sym - 144, 9)
        } elif sym < 280 {
            self.put_code(sym - 256, 7)
        } else {
            self.put_code(192 + sym - 280, 8)
        }
    }

    def emit_match(self, length: int, distance: int) {
        k = length_sym(length) - 257
        self.emit_lit(257 + k)
        eb = length_extra(k)
        if eb > 0 {
            self.put_raw(length - length_base(k), eb)
        }
        dk = dist_sym(distance)
        self.put_code(dk, 5)
        db = dist_extra(dk)
        if db > 0 {
            self.put_raw(distance - dist_base(dk), db)
        }
    }

    def fixed_block(self, src: @Bytes, level: int) {
        self.put_raw(1, 1)   # BFINAL
        self.put_raw(1, 2)   # BTYPE = fixed Huffman
        n = src.len
        hash_bits = 65536
        i = 0
        while i < hash_bits {
            self.head.push(-1)
            i = i + 1
        }
        i = 0
        while i < 32768 {
            self.prev.push(-1)
            i = i + 1
        }
        max_chain = 64
        if level <= 3 {
            max_chain = 16
        } elif level >= 7 {
            max_chain = 256
        }
        i = 0
        while i < n {
            best_len = 0
            best_dist = 0
            if i + 2 < n {
                h = hash3(src.get(i), src.get(i + 1), src.get(i + 2))
                cand = self.head.get(h)
                self.prev.set(i & 32767, cand)
                self.head.set(h, i)
                maxlen = n - i
                if maxlen > 258 {
                    maxlen = 258
                }
                chain = 0
                while cand >= 0 and chain < max_chain {
                    if i - cand > 32768 {
                        break
                    }
                    if best_len > 0 and src.get(cand + best_len) != src.get(i + best_len) {
                        cand = self.prev.get(cand & 32767)
                        chain = chain + 1
                        continue
                    }
                    l = 0
                    while l < maxlen and src.get(cand + l) == src.get(i + l) {
                        l = l + 1
                    }
                    if l > best_len {
                        best_len = l
                        best_dist = i - cand
                        if l >= maxlen {
                            break
                        }
                    }
                    cand = self.prev.get(cand & 32767)
                    chain = chain + 1
                }
            }
            if best_len >= 3 {
                self.emit_match(best_len, best_dist)
                k = i + 1
                stop = i + best_len
                while k < stop {
                    if k + 2 < n {
                        h = hash3(src.get(k), src.get(k + 1), src.get(k + 2))
                        self.prev.set(k & 32767, self.head.get(h))
                        self.head.set(h, k)
                    }
                    k = k + 1
                }
                i = i + best_len
            } else {
                self.emit_lit(src.get(i))
                i = i + 1
            }
        }
        self.emit_lit(256)   # end of block
    }

    def stored_stream(self, src: @Bytes) {
        n = src.len
        if n == 0 {
            self.put_raw(1, 1)
            self.put_raw(0, 2)
            self.align()
            self.out.push(0)
            self.out.push(0)
            self.out.push(255)
            self.out.push(255)
            return
        }
        pos = 0
        while pos < n {
            blen = n - pos
            if blen > 65535 {
                blen = 65535
            }
            last = 0
            if pos + blen >= n {
                last = 1
            }
            self.put_raw(last, 1)
            self.put_raw(0, 2)
            self.align()
            self.out.push(blen & 255)
            self.out.push((blen >> 8) & 255)
            nb = blen ^ 65535
            self.out.push(nb & 255)
            self.out.push((nb >> 8) & 255)
            if blen > 0 {
                self.out.append_mem(int_to_ptr(ptr_to_int(src.data) + pos), blen)
            }
            pos = pos + blen
        }
    }

    def gzip_stream(self, src: @Bytes, level: int) {
        self.out.push(31)
        self.out.push(139)
        self.out.push(8)
        self.out.push(0)
        self.out.push(0)
        self.out.push(0)
        self.out.push(0)
        self.out.push(0)
        xfl = 0
        if level == 9 {
            xfl = 2
        } elif level == 1 {
            xfl = 4
        }
        self.out.push(xfl)
        self.out.push(255)
        if level == 0 {
            self.stored_stream(src)
        } else {
            self.fixed_block(src, level)
            self.align()
        }
        crc = crc32_mem(src.data, src.len)
        n = src.len
        self.out.push(crc & 255)
        self.out.push((crc >> 8) & 255)
        self.out.push((crc >> 16) & 255)
        self.out.push((crc >> 24) & 255)
        self.out.push(n & 255)
        self.out.push((n >> 8) & 255)
        self.out.push((n >> 16) & 255)
        self.out.push((n >> 24) & 255)
    }
}

def hash3(a: int, b: int, c: int) -> int {
    v = (a << 16) | (b << 8) | c
    return ((v * 2654435761) >> 16) & 65535
}

def length_sym(n: int) -> int {
    k = 28
    while k > 0 {
        if n >= length_base(k) {
            return 257 + k
        }
        k = k - 1
    }
    return 257
}

def dist_sym(d: int) -> int {
    k = 29
    while k > 0 {
        if d >= dist_base(k) {
            return k
        }
        k = k - 1
    }
    return 0
}

# Compress into a gzip container; level 0-9, negatives use 6.
# Level 0 emits stored blocks; levels 1-9 emit one fixed-Huffman LZ77 block.
public def compress_level(src: @Bytes, level: int) -> GzipResult {
    r = new_result()
    lv = level
    if lv < 0 {
        lv = 6
    }
    if lv > 9 {
        lv = 9
    }
    d = Deflater()
    d.init()
    d.gzip_stream(src, lv)
    r.data = d.out
    r.members = 1
    r.ok = True
    return r
}

public def compress(src: @Bytes) -> GzipResult {
    return compress_level(src, 6)
}

# Compress memory into a .gz file on disk (binary safe).
public def compress_to_file(src: @Bytes, path: str, level: int) -> GzipResult {
    c = compress_level(src, level)
    if not c.ok {
        return c
    }
    out = c.data
    wr = bytes.write_bytes(path, @out)
    if not wr.ok {
        r = new_result()
        r.error = wr.error
        return r
    }
    return c
}

# Read and decompress a .gz file from disk (binary safe).
public def decompress_file(path: str) -> GzipResult {
    fr = bytes.read_bytes(path)
    if not fr.ok {
        r = new_result()
        r.error = fr.error
        return r
    }
    src = fr.data
    return decompress(src)
}

# Same as decompress_file, with an output limit (limit <= 0 means unlimited).
public def decompress_file_limit(path: str, limit: int) -> GzipResult {
    fr = bytes.read_bytes(path)
    if not fr.ok {
        r = new_result()
        r.error = fr.error
        return r
    }
    src = fr.data
    return decompress_limit(src, limit)
}
