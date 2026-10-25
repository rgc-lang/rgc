# RGC standard library: bytes
#
# Binary-safe byte buffer: len is tracked explicitly, no NUL termination needed.
# It uses the compiler's built-in buf_* functions and libc memchr/memmem underneath, without string-copy semantics.
#
# Usage:
#   b = bytes.from_str("abc")
#   b.push(0)
#   print(b.len)            # 4
#   print(b.find_byte(99, 0))  # 2

extern def memchr(p: str, c: int, n: int) -> str
extern def memmem(h: str, hn: int, n: str, nn: int) -> str
extern def open(path: str, flags: int, mode: int) -> int
extern def close(fd: int) -> int
extern def read(fd: int, buf: str, n: int) -> int
extern def pwrite(fd: int, buf: str, n: int, off: int) -> int
extern def lseek(fd: int, off: int, whence: int) -> int
extern def free(p: str) -> None

public class Bytes {
    data: str
    len: int
    cap: int

    def ensure(self, need: int) {
        if need > self.cap {
            cap = self.cap
            if cap < 64 {
                cap = 64
            }
            while cap < need {
                cap = cap * 2
            }
            self.data = buf_realloc(self.data, cap)
            self.cap = cap
        }
    }

    def push(self, v: int) {
        self.ensure(self.len + 1)
        buf_set8(self.data, self.len, v)
        self.len = self.len + 1
    }

    def append_mem(self, p: str, n: int) {
        if n > 0 {
            self.ensure(self.len + n)
            buf_copy(self.data, self.len, p, 0, n)
            self.len = self.len + n
        }
    }

    def append(self, other: @Bytes) {
        self.append_mem(other.data, other.len)
    }

    def slice(self, start: int, end: int) -> Bytes {
        s = start
        e = end
        if s < 0 {
            s = 0
        }
        if e > self.len {
            e = self.len
        }
        b = bytes_new(e - s)
        if e > s {
            b.append_mem(int_to_ptr(ptr_to_int(self.data) + s), e - s)
        }
        return b
    }

    def to_str(self) -> str {
        return buf_to_str(self.data, self.len)
    }

    def get(self, i: int) -> int {
        return buf_get8(self.data, i)
    }

    def set(self, i: int, v: int) {
        buf_set8(self.data, i, v)
    }

    # Substring search: returns the start index, or -1 when not found.
    def find(self, pat: str, start: int) -> int {
        n = pat.len()
        if n == 0 {
            return start
        }
        s = start
        if s < 0 {
            s = 0
        }
        if s + n > self.len {
            return -1
        }
        base = int_to_ptr(ptr_to_int(self.data) + s)
        p = memmem(base, self.len - s, pat, n)
        if ptr_is_null(p) {
            return -1
        }
        return ptr_to_int(p) - ptr_to_int(self.data)
    }

    def find_byte(self, b: int, start: int) -> int {
        s = start
        if s < 0 {
            s = 0
        }
        if s >= self.len {
            return -1
        }
        base = int_to_ptr(ptr_to_int(self.data) + s)
        p = memchr(base, b, self.len - s)
        if ptr_is_null(p) {
            return -1
        }
        return ptr_to_int(p) - ptr_to_int(self.data)
    }

    def starts_with(self, pat: str) -> bool {
        n = pat.len()
        if n > self.len {
            return False
        }
        i = 0
        while i < n {
            if buf_get8(self.data, i) != pat.char_at(i) {
                return False
            }
            i = i + 1
        }
        return True
    }

    def has_nul(self) -> bool {
        return self.find_byte(0, 0) >= 0
    }

    def truncate(self, n: int) {
        if n >= 0 and n < self.len {
            self.len = n
        }
    }

    def drop_front(self, n: int) {
        if n > 0 {
            k = n
            if k > self.len {
                k = self.len
            }
            if k < self.len {
                buf_copy(self.data, 0, self.data, k, self.len - k)
            }
            self.len = self.len - k
        }
    }

    def clear(self) {
        self.len = 0
    }
}

public def bytes_new(cap: int) -> Bytes {
    c = cap
    if c < 1 {
        c = 1
    }
    b = Bytes()
    b.data = buf_alloc(c)
    # Zero-fill: freshly malloc'd memory is uninitialized; crypto code reads whole
    # fixed-size regions, so undefined bytes must never leak into results.
    buf_zero(b.data, c)
    b.len = 0
    b.cap = c
    return b
}

public def bytes_from_str(s: str) -> Bytes {
    b = bytes_new(s.len())
    b.append_mem(s, s.len())
    return b
}

public def bytes_from_mem(p: str, n: int) -> Bytes {
    b = bytes_new(n)
    b.append_mem(p, n)
    return b
}

public def bytes_concat(a: @Bytes, b: @Bytes) -> Bytes {
    out = bytes_new(a.len + b.len)
    out.append(a)
    out.append(b)
    return out
}

# Binary file I/O result. io.read_file/io.write_file are string based (C string semantics),
# so compressed/archived payloads containing NUL bytes must go through this module instead.
public class BytesFileResult {
    ok: bool
    error: str
    data: Bytes
    size: int
}

def file_error(msg: str) -> BytesFileResult {
    r = BytesFileResult()
    r.ok = False
    r.error = msg
    r.data = bytes_new(0)
    r.size = 0
    return r
}

# Read a whole file as raw bytes (binary safe, no strlen truncation).
public def read_bytes(path: str) -> BytesFileResult {
    fd = open(path, 0, 0)
    if fd < 0 {
        return file_error("cannot open file")
    }
    end = lseek(fd, 0, 2)
    if end < 0 {
        close(fd)
        return file_error("cannot read file")
    }
    lseek(fd, 0, 0)
    buf = buf_alloc(end + 1)
    got = 0
    while got < end {
        k = read(fd, int_to_ptr(ptr_to_int(buf) + got), end - got)
        if k <= 0 {
            break
        }
        got = got + k
    }
    close(fd)
    if got != end {
        free(buf)
        return file_error("short read")
    }
    r = BytesFileResult()
    r.ok = True
    r.error = ""
    r.data = bytes_from_mem(buf, got)
    r.size = got
    free(buf)
    return r
}

# Write raw bytes to a file, replacing it (binary safe, no strlen truncation).
public def write_bytes(path: str, data: @Bytes) -> BytesFileResult {
    fd = open(path, 577, 438)
    if fd < 0 {
        return file_error("cannot open file")
    }
    n = 0
    while n < data.len {
        k = pwrite(fd, int_to_ptr(ptr_to_int(data.data) + n), data.len - n, n)
        if k <= 0 {
            break
        }
        n = n + k
    }
    close(fd)
    r = BytesFileResult()
    r.data = bytes_new(0)
    r.size = n
    if n != data.len {
        r.ok = False
        r.error = "short write"
        return r
    }
    r.ok = True
    r.error = ""
    return r
}
