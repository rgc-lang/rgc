# RGC standard library: tar
#
# Pure-RGC tar archive reader/writer (POSIX ustar + GNU LongLink + PAX extended headers).
# Works on in-memory Bytes; combine with gzip for .tar.gz, and with bytes.read_bytes/write_bytes
# for binary-safe files.
#
# Usage:
#   import tar
#   import bytes
#   b = tar.builder()
#   b.add_file("hello.txt", bytes.bytes_from_str("hello\n"))
#   b.add_dir("logs")
#   r = tar.create_from(b)
#   if r.ok { bytes.write_bytes("out.tar", r.data) }
#
#   l = tar.list_entries(@src)
#   f = tar.extract(@src, "hello.txt")
#
# Entry kinds: 0 file, 1 hard link, 2 symlink, 3 char device, 4 block device,
# 5 directory, 6 fifo, 7 other. create() writes files (0) and directories (5).
# Names longer than 100 bytes are emitted as GNU LongLink records; readers accept
# ustar prefix, GNU LongLink and PAX path/linkpath/size.

import bytes

public class TarEntry {
    name: str
    size: int
    mode: int
    mtime: int
    kind: int
    typeflag: int
    linkname: str
    offset: int
}

public class TarResult {
    ok: bool
    error: str
    entries: List[TarEntry]
    data: Bytes
}

public class TarFileResult {
    ok: bool
    error: str
    data: Bytes
    entry: TarEntry
}

public class TarInput {
    name: str
    data: Bytes
    kind: int
    mode: int
    mtime: int
}

class PaxInfo {
    path: str
    linkpath: str
    size: int
    has_size: bool
    mtime: int
    has_mtime: bool
}

# Class str fields start as null pointers; initialize before comparing/measuring them.
def new_pax() -> PaxInfo {
    p = PaxInfo()
    p.path = ""
    p.linkpath = ""
    p.size = 0
    p.has_size = False
    p.mtime = 0
    p.has_mtime = False
    return p
}

public class TarBuilder {
    items: List[TarInput]

    def add_entry(self, name: str, data: @Bytes, kind: int, mode: int, mtime: int) {
        it = TarInput()
        it.name = name
        it.data = bytes.bytes_from_mem(data.data, data.len)
        it.kind = kind
        it.mode = mode
        it.mtime = mtime
        self.items.push(it)
    }

    def add_file(self, name: str, data: @Bytes) {
        self.add_entry(name, data, 0, 420, 0)
    }

    def add_file_mode(self, name: str, data: @Bytes, mode: int, mtime: int) {
        self.add_entry(name, data, 0, mode, mtime)
    }

    def add_dir(self, name: str) {
        empty = bytes.bytes_new(0)
        self.add_entry(name, @empty, 5, 493, 0)
    }

    def finish(self) -> TarResult {
        xs = self.items
        return create(@xs)
    }
}

def tar_error(msg: str) -> TarResult {
    r = TarResult()
    r.ok = False
    r.error = msg
    r.entries = List[TarEntry]()
    r.data = bytes.bytes_new(0)
    return r
}

def file_error(msg: str) -> TarFileResult {
    r = TarFileResult()
    r.ok = False
    r.error = msg
    r.data = bytes.bytes_new(0)
    r.entry = TarEntry()
    return r
}

def round_up(n: int) -> int {
    rem = n % 512
    if rem == 0 {
        return n
    }
    return n + (512 - rem)
}

# Octal or GNU base-256 numeric header field.
def read_oct(src: @Bytes, off: int, n: int) -> int {
    i = 0
    while i < n {
        c = src.get(off + i)
        if c != 0 and c != 32 {
            break
        }
        i = i + 1
    }
    if i >= n {
        return 0
    }
    c0 = src.get(off + i)
    if (c0 & 128) != 0 {
        v = c0 & 127
        i = i + 1
        while i < n {
            v = v * 256 + src.get(off + i)
            i = i + 1
        }
        return v
    }
    v = 0
    while i < n {
        d = src.get(off + i)
        if d < 48 or d > 55 {
            break
        }
        v = v * 8 + (d - 48)
        i = i + 1
    }
    return v
}

def read_str(src: @Bytes, off: int, maxlen: int) -> str {
    n = 0
    while n < maxlen and src.get(off + n) != 0 {
        n = n + 1
    }
    if n == 0 {
        return ""
    }
    return src.slice(off, off + n).to_str()
}

def cstr_data(src: @Bytes, off: int, n: int) -> str {
    k = 0
    while k < n and src.get(off + k) != 0 {
        k = k + 1
    }
    if k == 0 {
        return ""
    }
    return src.slice(off, off + k).to_str()
}

def header_sum(src: @Bytes, off: int) -> int {
    s = 0
    i = 0
    while i < 512 {
        if i >= 148 and i < 156 {
            s = s + 32
        } else {
            s = s + src.get(off + i)
        }
        i = i + 1
    }
    return s
}

def is_zero_block(src: @Bytes, off: int) -> bool {
    i = 0
    while i < 512 {
        if src.get(off + i) != 0 {
            return False
        }
        i = i + 1
    }
    return True
}

def dec_parse(s: str) -> int {
    i = 0
    neg = False
    if s.len() > 0 and s.char_at(0) == 45 {
        neg = True
        i = 1
    }
    v = 0
    while i < s.len() {
        c = s.char_at(i)
        if c < 48 or c > 57 {
            break
        }
        v = v * 10 + (c - 48)
        i = i + 1
    }
    if neg {
        return -v
    }
    return v
}

def kind_from_typeflag(typ: int) -> int {
    if typ == 0 or typ == 48 {
        return 0
    }
    if typ == 49 {
        return 1
    }
    if typ == 50 {
        return 2
    }
    if typ == 51 {
        return 3
    }
    if typ == 52 {
        return 4
    }
    if typ == 53 {
        return 5
    }
    if typ == 54 {
        return 6
    }
    return 7
}

# PAX extended records: "<len> <key>=<value>\n".
def parse_pax(src: @Bytes, off: int, n: int, info: @var PaxInfo) {
    i = 0
    while i < n {
        start = i
        rec = 0
        while i < n {
            c = src.get(off + i)
            if c == 32 {
                break
            }
            if c < 48 or c > 57 {
                break
            }
            rec = rec * 10 + (c - 48)
            i = i + 1
        }
        if rec <= 0 {
            return
        }
        end = start + rec
        if end > n {
            return
        }
        if i < n and src.get(off + i) == 32 {
            i = i + 1
        }
        ks = i
        while i < end and src.get(off + i) != 61 {
            i = i + 1
        }
        ke = i
        if i < end {
            i = i + 1
        }
        vs = i
        ve = i
        while ve < end and src.get(off + ve) != 10 {
            ve = ve + 1
        }
        key = src.slice(off + ks, off + ke).to_str()
        val = src.slice(off + vs, off + ve).to_str()
        if key == "path" {
            info.path = val
        } elif key == "linkpath" {
            info.linkpath = val
        } elif key == "size" {
            info.size = dec_parse(val)
            info.has_size = True
        } elif key == "mtime" {
            info.mtime = dec_parse(val)
            info.has_mtime = True
        }
        i = end
    }
}

# Parse an archive and return its entries (file data stays in the source buffer).
public def list_entries(src: @Bytes) -> TarResult {
    r = TarResult()
    r.ok = False
    r.error = ""
    r.entries = List[TarEntry]()
    r.data = bytes.bytes_new(0)
    p = 0
    pending_name = ""
    pending_link = ""
    gp = new_pax()
    pax = new_pax()
    while p + 512 <= src.len {
        if is_zero_block(src, p) {
            r.ok = True
            return r
        }
        stored = read_oct(src, p + 148, 8)
        actual = header_sum(src, p)
        if stored != actual {
            r.error = "invalid tar checksum"
            return r
        }
        size = read_oct(src, p + 124, 12)
        dataoff = p + 512
        if size < 0 {
            r.error = "invalid tar size"
            return r
        }
        if dataoff + size > src.len {
            r.error = "truncated tar data"
            return r
        }
        typ = src.get(p + 156)
        if typ == 120 {
            # 'x': PAX records for the next entry.
            pax = new_pax()
            parse_pax(src, dataoff, size, pax)
            p = dataoff + round_up(size)
        } elif typ == 103 {
            # 'g': global PAX records.
            parse_pax(src, dataoff, size, gp)
            p = dataoff + round_up(size)
        } elif typ == 76 {
            pending_name = cstr_data(src, dataoff, size)
            p = dataoff + round_up(size)
        } elif typ == 75 {
            pending_link = cstr_data(src, dataoff, size)
            p = dataoff + round_up(size)
        } else {
            name = read_str(src, p, 100)
            magic = read_str(src, p + 257, 6)
            ver = read_str(src, p + 263, 2)
            if magic == "ustar" and ver == "00" {
                prefix = read_str(src, p + 345, 155)
                if prefix.len() > 0 {
                    name = prefix + "/" + name
                }
            }
            link = read_str(src, p + 157, 100)
            if gp.path.len() > 0 {
                name = gp.path
            }
            if pax.path.len() > 0 {
                name = pax.path
            }
            if pending_name.len() > 0 {
                name = pending_name
                pending_name = ""
            }
            if gp.linkpath.len() > 0 {
                link = gp.linkpath
            }
            if pax.linkpath.len() > 0 {
                link = pax.linkpath
            }
            if pending_link.len() > 0 {
                link = pending_link
                pending_link = ""
            }
            real = size
            if gp.has_size {
                real = gp.size
            }
            if pax.has_size {
                real = pax.size
            }
            if real < 0 {
                r.error = "invalid tar size"
                return r
            }
            if dataoff + real > src.len {
                r.error = "truncated tar data"
                return r
            }
            e = TarEntry()
            e.name = name
            e.size = real
            e.mode = read_oct(src, p + 100, 8)
            e.mtime = read_oct(src, p + 136, 12)
            if pax.has_mtime {
                e.mtime = pax.mtime
            }
            e.kind = kind_from_typeflag(typ)
            e.typeflag = typ
            e.linkname = link
            e.offset = dataoff
            r.entries.push(e)
            p = dataoff + round_up(real)
            pax = new_pax()
        }
    }
    if p < src.len {
        r.error = "truncated tar header"
        return r
    }
    r.ok = True
    return r
}

# Extract one regular file by name.
public def extract(src: @Bytes, name: str) -> TarFileResult {
    lr = list_entries(src)
    if not lr.ok {
        return file_error(lr.error)
    }
    i = 0
    while i < lr.entries.len() {
        e = lr.entries.get(i)
        if e.name == name {
            if e.kind != 0 {
                return file_error("not a regular file")
            }
            if e.offset + e.size > src.len {
                return file_error("truncated tar data")
            }
            r = TarFileResult()
            r.ok = True
            r.error = ""
            r.data = src.slice(e.offset, e.offset + e.size)
            r.entry = e
            return r
        }
        i = i + 1
    }
    return file_error("entry not found")
}

def put_str_n(h: @var Bytes, off: int, s: str, max: int) {
    n = s.len()
    if n > max {
        n = max
    }
    i = 0
    while i < n {
        h.set(off + i, s.char_at(i))
        i = i + 1
    }
}

def put_oct(h: @var Bytes, off: int, digits: int, val: int) {
    i = digits - 1
    v = val
    while i >= 0 {
        h.set(off + i, 48 + v % 8)
        v = v / 8
        i = i - 1
    }
}

def make_header(name: str, size: int, mode: int, mtime: int, typeflag: int, linkname: str) -> Bytes {
    h = bytes.bytes_new(512)
    i = 0
    while i < 512 {
        h.push(0)
        i = i + 1
    }
    put_str_n(h, 0, name, 100)
    put_oct(h, 100, 7, mode)
    put_oct(h, 108, 7, 0)
    put_oct(h, 116, 7, 0)
    put_oct(h, 124, 11, size)
    put_oct(h, 136, 11, mtime)
    i = 148
    while i < 156 {
        h.set(i, 32)
        i = i + 1
    }
    h.set(156, typeflag)
    put_str_n(h, 157, linkname, 100)
    put_str_n(h, 257, "ustar", 5)
    h.set(263, 48)
    h.set(264, 48)
    s = 0
    i = 0
    while i < 512 {
        s = s + h.get(i)
        i = i + 1
    }
    put_oct(h, 148, 6, s)
    h.set(154, 0)
    h.set(155, 32)
    return h
}

def pad_to(out: @var Bytes, n: int) {
    rem = n % 512
    if rem != 0 {
        k = 512 - rem
        while k > 0 {
            out.push(0)
            k = k - 1
        }
    }
}

# GNU LongLink record for names > 100 bytes ('L' name, 'K' linkname).
def append_long(out: @var Bytes, name: str, typeflag: int) {
    n = name.len() + 1
    h = make_header("././@LongLink", n, 0, 0, typeflag, "")
    out.append_mem(h.data, h.len)
    i = 0
    while i < name.len() {
        out.push(name.char_at(i))
        i = i + 1
    }
    out.push(0)
    pad_to(out, n)
}

# Build a tar archive from the given entries.
public def create(files: @List[TarInput]) -> TarResult {
    out = bytes.bytes_new(1024)
    i = 0
    while i < files.len() {
        f = files.get(i)
        if f.name.len() == 0 {
            return tar_error("empty entry name")
        }
        kind = f.kind
        if kind != 0 and kind != 5 {
            return tar_error("unsupported entry kind")
        }
        name = f.name
        mode = f.mode
        typ = 48
        if kind == 5 {
            typ = 53
            if mode == 0 {
                mode = 493
            }
            if name.char_at(name.len() - 1) != 47 {
                name = name + "/"
            }
        } elif mode == 0 {
            mode = 420
        }
        data = f.data
        size = 0
        if kind == 0 {
            size = data.len
        }
        if name.len() > 100 {
            append_long(out, name, 76)
        }
        h = make_header(name, size, mode, f.mtime, typ, "")
        out.append_mem(h.data, h.len)
        if kind == 0 and size > 0 {
            out.append_mem(data.data, size)
        }
        pad_to(out, size)
        i = i + 1
    }
    i = 0
    while i < 1024 {
        out.push(0)
        i = i + 1
    }
    r = TarResult()
    r.ok = True
    r.error = ""
    r.entries = List[TarEntry]()
    r.data = out
    return r
}

public def builder() -> TarBuilder {
    b = TarBuilder()
    b.items = List[TarInput]()
    return b
}

# Convenience: finish a builder (keeps call sites symmetric with tar.builder()).
public def create_from(b: TarBuilder) -> TarResult {
    xs = b.items
    return create(@xs)
}
