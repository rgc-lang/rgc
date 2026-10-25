# RGC standard library: bin
#
# Binary helpers shared by the crypto/TLS modules: hex conversion, big-endian
# integer load/store, and constant-shape byte comparison.
#
# Usage:
#   import bin
#   b = bin.from_hex("48656c6c6f")
#   print(bin.to_hex(@b), bin.u16(@b, 0))

import bytes

public class HexResult {
    ok: bool
    data: Bytes
}

def hex_value(c: int) -> int {
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

public def hex_to_bytes(s: str) -> HexResult {
    r = HexResult()
    r.ok = False
    r.data = bytes.bytes_new(0)
    n = s.len()
    out = bytes.bytes_new(n / 2 + 1)
    i = 0
    while i + 1 < n {
        hi = hex_value(s.char_at(i))
        lo = hex_value(s.char_at(i + 1))
        if hi < 0 or lo < 0 {
            return r
        }
        out.push((hi << 4) | lo)
        i = i + 2
    }
    if i != n {
        return r
    }
    r.ok = True
    r.data = out
    return r
}

# Strict conversion; invalid input yields an empty buffer.
public def from_hex(s: str) -> Bytes {
    r = hex_to_bytes(s)
    if not r.ok {
        return bytes.bytes_new(0)
    }
    return r.data
}

public def to_hex(b: @Bytes) -> str {
    digits = "0123456789abcdef"
    out = ""
    i = 0
    while i < b.len {
        v = b.get(i)
        out = out + digits.slice(v >> 4, (v >> 4) + 1)
        out = out + digits.slice(v & 15, (v & 15) + 1)
        i = i + 1
    }
    return out
}

public def u8(b: @Bytes, off: int) -> int {
    if off < 0 or off >= b.len {
        return -1
    }
    return b.get(off)
}

public def u16(b: @Bytes, off: int) -> int {
    if off < 0 or off + 2 > b.len {
        return -1
    }
    return (b.get(off) << 8) | b.get(off + 1)
}

public def u24(b: @Bytes, off: int) -> int {
    if off < 0 or off + 3 > b.len {
        return -1
    }
    return (b.get(off) << 16) | (b.get(off + 1) << 8) | b.get(off + 2)
}

public def u32(b: @Bytes, off: int) -> int {
    if off < 0 or off + 4 > b.len {
        return -1
    }
    return (b.get(off) << 24) | (b.get(off + 1) << 16) |
           (b.get(off + 2) << 8) | b.get(off + 3)
}

public def u64(b: @Bytes, off: int) -> int {
    if off < 0 or off + 8 > b.len {
        return -1
    }
    hi = u32(b, off)
    lo = u32(b, off + 4)
    return (hi << 32) | lo
}

public def put_u8(b: @var Bytes, v: int) {
    b.push(v & 255)
}

public def put_u16(b: @var Bytes, v: int) {
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

public def put_u24(b: @var Bytes, v: int) {
    b.push((v >> 16) & 255)
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

public def put_u32(b: @var Bytes, v: int) {
    b.push((v >> 24) & 255)
    b.push((v >> 16) & 255)
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

public def put_u64(b: @var Bytes, v: int) {
    put_u32(b, (v >> 32) & 4294967295)
    put_u32(b, v & 4294967295)
}

# Compare without early exit so tag checks do not leak the first differing byte.
public def equal(a: @Bytes, b: @Bytes) -> bool {
    if a.len != b.len {
        return False
    }
    diff = 0
    i = 0
    while i < a.len {
        diff = diff | (a.get(i) ^ b.get(i))
        i = i + 1
    }
    return diff == 0
}

# Append a TLS-style vector: 2-byte length followed by the payload.
public def append_vec16(out: @var Bytes, payload: @Bytes) {
    put_u16(out, payload.len)
    out.append(payload)
}

public def append_vec8(out: @var Bytes, payload: @Bytes) {
    put_u8(out, payload.len)
    out.append(payload)
}

public def concat(a: @Bytes, b: @Bytes) -> Bytes {
    out = bytes.bytes_new(a.len + b.len)
    out.append(a)
    out.append(b)
    return out
}

public def slice_of(b: @Bytes, start: int, end: int) -> Bytes {
    return b.slice(start, end)
}
