# RGC standard library: entropy
#
# Cryptographic randomness: reads /dev/urandom through libc open/read/close.
# Used by TLS (client random, key generation, PSS salt, ECDSA nonces). This is the
# only entropy source; if /dev/urandom cannot be opened, fill() keeps the buffer
# zeroed and ok() reports False, and callers must fail the operation.
#
# Usage:
#   import entropy
#   b = entropy.bytes_random(32)     # empty result when /dev/urandom is unavailable
#   if b.len == 0 { print("no entropy") }

extern def open(path: str, flags: int, mode: int) -> int
extern def read(fd: int, buf: str, count: int) -> int
extern def close(fd: int) -> int

import bytes

def fill(p: str, n: int) -> bool {
    fd = open("/dev/urandom", 0, 0)   # O_RDONLY
    if fd < 0 {
        return False
    }
    got = 0
    while got < n {
        k = read(fd, int_to_ptr(ptr_to_int(p) + got), n - got)
        if k <= 0 {
            close(fd)
            return False
        }
        got = got + k
    }
    close(fd)
    return True
}

# Random bytes appended to a fresh, zero-filled buffer.
public def bytes_random(n: int) -> Bytes {
    b = bytes_new(n)
    b.len = n
    if not fill(b.data, n) {
        b.len = 0
    }
    return b
}

# Random bytes written into an existing buffer.
public def fill_bytes(b: @var Bytes, n: int) -> bool {
    if n > b.cap {
        return False
    }
    if not fill(b.data, n) {
        return False
    }
    if n > b.len {
        b.len = n
    }
    return True
}

public def random_bytes_into(p: str, n: int) -> bool {
    return fill(p, n)
}
