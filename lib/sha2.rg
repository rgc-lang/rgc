# RGC standard library: sha2
#
# Pure RGC SHA-256 / SHA-384 / SHA-512 (FIPS 180-4). No OpenSSL: compression
# functions, padding and the streaming contexts are implemented here.
#
# Usage:
#   import sha2
#   d = sha2.sha256(@data)          # bytes.Bytes, 32 bytes
#   s = sha2.sha256_new()
#   sha2.sha256_update(@var s, @part1)
#   sha2.sha256_update(@var s, @part2)
#   d = sha2.sha256_finish(@var s)
#
# Notes:
#   - 32-bit words are kept as positive i64 values masked with 0xffffffff;
#     64-bit words use the compiler's wrapping i64 arithmetic.
#   - sha256_finish/sha512_finish consume the context; use sha256_digest for a
#     non-destructive copy.

import bytes

def rotr32(x: int, n: int) -> int {
    return ((x >> n) | (x << (32 - n))) & 4294967295
}

def rotr64(x: int, n: int) -> int {
    if n == 0 {
        return x
    }
    lo = (x >> n) & ((1 << (64 - n)) - 1)
    hi = x << (64 - n)
    return lo | hi
}

def shr64(x: int, n: int) -> int {
    if n == 0 {
        return x
    }
    return (x >> n) & ((1 << (64 - n)) - 1)
}

def k256() -> List[int] {
    k = List[int]()
    k.push(1116352408)
    k.push(1899447441)
    k.push(3049323471)
    k.push(3921009573)
    k.push(961987163)
    k.push(1508970993)
    k.push(2453635748)
    k.push(2870763221)
    k.push(3624381080)
    k.push(310598401)
    k.push(607225278)
    k.push(1426881987)
    k.push(1925078388)
    k.push(2162078206)
    k.push(2614888103)
    k.push(3248222580)
    k.push(3835390401)
    k.push(4022224774)
    k.push(264347078)
    k.push(604807628)
    k.push(770255983)
    k.push(1249150122)
    k.push(1555081692)
    k.push(1996064986)
    k.push(2554220882)
    k.push(2821834349)
    k.push(2952996808)
    k.push(3210313671)
    k.push(3336571891)
    k.push(3584528711)
    k.push(113926993)
    k.push(338241895)
    k.push(666307205)
    k.push(773529912)
    k.push(1294757372)
    k.push(1396182291)
    k.push(1695183700)
    k.push(1986661051)
    k.push(2177026350)
    k.push(2456956037)
    k.push(2730485921)
    k.push(2820302411)
    k.push(3259730800)
    k.push(3345764771)
    k.push(3516065817)
    k.push(3600352804)
    k.push(4094571909)
    k.push(275423344)
    k.push(430227734)
    k.push(506948616)
    k.push(659060556)
    k.push(883997877)
    k.push(958139571)
    k.push(1322822218)
    k.push(1537002063)
    k.push(1747873779)
    k.push(1955562222)
    k.push(2024104815)
    k.push(2227730452)
    k.push(2361852424)
    k.push(2428436474)
    k.push(2756734187)
    k.push(3204031479)
    k.push(3329325298)
    return k
}

def h256() -> List[int] {
    h = List[int]()
    h.push(1779033703)
    h.push(3144134277)
    h.push(1013904242)
    h.push(2773480762)
    h.push(1359893119)
    h.push(2600822924)
    h.push(528734635)
    h.push(1541459225)
    return h
}

public class Sha256 {
    h: List[int]
    k: List[int]
    pending: Bytes
    total: int
}

public def sha256_new() -> Sha256 {
    s = Sha256()
    s.h = h256()
    s.k = k256()
    s.pending = bytes.bytes_new(64)
    s.total = 0
    return s
}

public def sha256_clone(s: @Sha256) -> Sha256 {
    c = Sha256()
    c.h = List[int]()
    i = 0
    while i < 8 {
        c.h.push(s.h.get(i))
        i = i + 1
    }
    c.k = k256()
    c.pending = bytes.bytes_from_mem(s.pending.data, s.pending.len)
    c.total = s.total
    return c
}

def sha256_compress_at(s: @var Sha256, p: str, off: int) {
    w = List[int]()
    i = 0
    while i < 16 {
        w.push((buf_get8(p, off + i * 4) << 24) |
               (buf_get8(p, off + i * 4 + 1) << 16) |
               (buf_get8(p, off + i * 4 + 2) << 8) |
               buf_get8(p, off + i * 4 + 3))
        i = i + 1
    }
    i = 16
    while i < 64 {
        x = w.get(i - 15)
        y = w.get(i - 2)
        s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3)
        s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10)
        w.push((w.get(i - 16) + s0 + w.get(i - 7) + s1) & 4294967295)
        i = i + 1
    }

    a = s.h.get(0)
    b = s.h.get(1)
    c = s.h.get(2)
    d = s.h.get(3)
    e = s.h.get(4)
    f = s.h.get(5)
    g = s.h.get(6)
    h = s.h.get(7)
    i = 0
    while i < 64 {
        S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
        ch = (e & f) ^ ((e ^ 4294967295) & g)
        t1 = (h + S1 + ch + s.k.get(i) + w.get(i)) & 4294967295
        S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
        maj = (a & b) ^ (a & c) ^ (b & c)
        t2 = (S0 + maj) & 4294967295
        h = g
        g = f
        f = e
        e = (d + t1) & 4294967295
        d = c
        c = b
        b = a
        a = (t1 + t2) & 4294967295
        i = i + 1
    }
    s.h.set(0, (s.h.get(0) + a) & 4294967295)
    s.h.set(1, (s.h.get(1) + b) & 4294967295)
    s.h.set(2, (s.h.get(2) + c) & 4294967295)
    s.h.set(3, (s.h.get(3) + d) & 4294967295)
    s.h.set(4, (s.h.get(4) + e) & 4294967295)
    s.h.set(5, (s.h.get(5) + f) & 4294967295)
    s.h.set(6, (s.h.get(6) + g) & 4294967295)
    s.h.set(7, (s.h.get(7) + h) & 4294967295)
}

public def sha256_update(s: @var Sha256, data: @Bytes) {
    s.total = s.total + data.len
    pos = 0
    if s.pending.len > 0 {
        while s.pending.len < 64 and pos < data.len {
            s.pending.push(data.get(pos))
            pos = pos + 1
        }
        if s.pending.len == 64 {
            sha256_compress_at(@var s, s.pending.data, 0)
            s.pending.len = 0
        }
    }
    while pos + 64 <= data.len {
        sha256_compress_at(@var s, data.data, pos)
        pos = pos + 64
    }
    while pos < data.len {
        s.pending.push(data.get(pos))
        pos = pos + 1
    }
}

public def sha256_finish(s: @var Sha256) -> Bytes {
    bits = s.total * 8
    s.pending.push(128)
    while s.pending.len % 64 != 56 {
        s.pending.push(0)
    }
    i = 0
    while i < 8 {
        s.pending.push((bits >> (56 - i * 8)) & 255)
        i = i + 1
    }
    pos = 0
    while pos < s.pending.len {
        sha256_compress_at(@var s, s.pending.data, pos)
        pos = pos + 64
    }
    s.pending.len = 0
    out = bytes.bytes_new(32)
    i = 0
    while i < 8 {
        v = s.h.get(i)
        out.push((v >> 24) & 255)
        out.push((v >> 16) & 255)
        out.push((v >> 8) & 255)
        out.push(v & 255)
        i = i + 1
    }
    return out
}

public def sha256_digest(s: @Sha256) -> Bytes {
    c = sha256_clone(@s)
    return sha256_finish(@var c)
}

public def sha256(data: @Bytes) -> Bytes {
    s = sha256_new()
    sha256_update(@var s, data)
    return sha256_finish(@var s)
}

# ---------------------------------------------------------------------------
# SHA-512 / SHA-384
# ---------------------------------------------------------------------------

# SHA-512 constants, expressed as hex literals to keep one source of truth.
def k512() -> List[int] {
    k = List[int]()
    k.push(0x428a2f98d728ae22)
    k.push(0x7137449123ef65cd)
    k.push(0xb5c0fbcfec4d3b2f)
    k.push(0xe9b5dba58189dbbc)
    k.push(0x3956c25bf348b538)
    k.push(0x59f111f1b605d019)
    k.push(0x923f82a4af194f9b)
    k.push(0xab1c5ed5da6d8118)
    k.push(0xd807aa98a3030242)
    k.push(0x12835b0145706fbe)
    k.push(0x243185be4ee4b28c)
    k.push(0x550c7dc3d5ffb4e2)
    k.push(0x72be5d74f27b896f)
    k.push(0x80deb1fe3b1696b1)
    k.push(0x9bdc06a725c71235)
    k.push(0xc19bf174cf692694)
    k.push(0xe49b69c19ef14ad2)
    k.push(0xefbe4786384f25e3)
    k.push(0x0fc19dc68b8cd5b5)
    k.push(0x240ca1cc77ac9c65)
    k.push(0x2de92c6f592b0275)
    k.push(0x4a7484aa6ea6e483)
    k.push(0x5cb0a9dcbd41fbd4)
    k.push(0x76f988da831153b5)
    k.push(0x983e5152ee66dfab)
    k.push(0xa831c66d2db43210)
    k.push(0xb00327c898fb213f)
    k.push(0xbf597fc7beef0ee4)
    k.push(0xc6e00bf33da88fc2)
    k.push(0xd5a79147930aa725)
    k.push(0x06ca6351e003826f)
    k.push(0x142929670a0e6e70)
    k.push(0x27b70a8546d22ffc)
    k.push(0x2e1b21385c26c926)
    k.push(0x4d2c6dfc5ac42aed)
    k.push(0x53380d139d95b3df)
    k.push(0x650a73548baf63de)
    k.push(0x766a0abb3c77b2a8)
    k.push(0x81c2c92e47edaee6)
    k.push(0x92722c851482353b)
    k.push(0xa2bfe8a14cf10364)
    k.push(0xa81a664bbc423001)
    k.push(0xc24b8b70d0f89791)
    k.push(0xc76c51a30654be30)
    k.push(0xd192e819d6ef5218)
    k.push(0xd69906245565a910)
    k.push(0xf40e35855771202a)
    k.push(0x106aa07032bbd1b8)
    k.push(0x19a4c116b8d2d0c8)
    k.push(0x1e376c085141ab53)
    k.push(0x2748774cdf8eeb99)
    k.push(0x34b0bcb5e19b48a8)
    k.push(0x391c0cb3c5c95a63)
    k.push(0x4ed8aa4ae3418acb)
    k.push(0x5b9cca4f7763e373)
    k.push(0x682e6ff3d6b2b8a3)
    k.push(0x748f82ee5defb2fc)
    k.push(0x78a5636f43172f60)
    k.push(0x84c87814a1f0ab72)
    k.push(0x8cc702081a6439ec)
    k.push(0x90befffa23631e28)
    k.push(0xa4506cebde82bde9)
    k.push(0xbef9a3f7b2c67915)
    k.push(0xc67178f2e372532b)
    k.push(0xca273eceea26619c)
    k.push(0xd186b8c721c0c207)
    k.push(0xeada7dd6cde0eb1e)
    k.push(0xf57d4f7fee6ed178)
    k.push(0x06f067aa72176fba)
    k.push(0x0a637dc5a2c898a6)
    k.push(0x113f9804bef90dae)
    k.push(0x1b710b35131c471b)
    k.push(0x28db77f523047d84)
    k.push(0x32caab7b40c72493)
    k.push(0x3c9ebe0a15c9bebc)
    k.push(0x431d67c49c100d4c)
    k.push(0x4cc5d4becb3e42b6)
    k.push(0x597f299cfc657e2a)
    k.push(0x5fcb6fab3ad6faec)
    k.push(0x6c44198c4a475817)
    return k
}

def h512() -> List[int] {
    h = List[int]()
    h.push(0x6a09e667f3bcc908)
    h.push(0xbb67ae8584caa73b)
    h.push(0x3c6ef372fe94f82b)
    h.push(0xa54ff53a5f1d36f1)
    h.push(0x510e527fade682d1)
    h.push(0x9b05688c2b3e6c1f)
    h.push(0x1f83d9abfb41bd6b)
    h.push(0x5be0cd19137e2179)
    return h
}

def h384() -> List[int] {
    h = List[int]()
    h.push(0xcbbb9d5dc1059ed8)
    h.push(0x629a292a367cd507)
    h.push(0x9159015a3070dd17)
    h.push(0x152fecd8f70e5939)
    h.push(0x67332667ffc00b31)
    h.push(0x8eb44a8768581511)
    h.push(0xdb0c2e0d64f98fa7)
    h.push(0x47b5481dbefa4fa4)
    return h
}

public class Sha512 {
    h: List[int]
    k: List[int]
    pending: Bytes
    total: int
    out_len: int
}

public def sha512_new(out_len: int) -> Sha512 {
    s = Sha512()
    if out_len == 48 {
        s.h = h384()
    } else {
        s.h = h512()
    }
    s.k = k512()
    s.pending = bytes.bytes_new(128)
    s.total = 0
    s.out_len = out_len
    return s
}

public def sha384_new() -> Sha512 {
    return sha512_new(48)
}

public def sha512_clone(s: @Sha512) -> Sha512 {
    c = sha512_new(s.out_len)
    i = 0
    while i < 8 {
        c.h.set(i, s.h.get(i))
        i = i + 1
    }
    c.pending = bytes.bytes_from_mem(s.pending.data, s.pending.len)
    c.total = s.total
    return c
}

def sha512_compress_at(s: @var Sha512, p: str, off: int) {
    w = List[int]()
    i = 0
    while i < 16 {
        w.push((buf_get8(p, off + i * 8) << 56) |
               (buf_get8(p, off + i * 8 + 1) << 48) |
               (buf_get8(p, off + i * 8 + 2) << 40) |
               (buf_get8(p, off + i * 8 + 3) << 32) |
               (buf_get8(p, off + i * 8 + 4) << 24) |
               (buf_get8(p, off + i * 8 + 5) << 16) |
               (buf_get8(p, off + i * 8 + 6) << 8) |
               buf_get8(p, off + i * 8 + 7))
        i = i + 1
    }
    i = 16
    while i < 80 {
        x = w.get(i - 15)
        y = w.get(i - 2)
        s0 = rotr64(x, 1) ^ rotr64(x, 8) ^ shr64(x, 7)
        s1 = rotr64(y, 19) ^ rotr64(y, 61) ^ shr64(y, 6)
        w.push(w.get(i - 16) + s0 + w.get(i - 7) + s1)
        i = i + 1
    }

    a = s.h.get(0)
    b = s.h.get(1)
    c = s.h.get(2)
    d = s.h.get(3)
    e = s.h.get(4)
    f = s.h.get(5)
    g = s.h.get(6)
    h = s.h.get(7)
    i = 0
    while i < 80 {
        S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
        ch = (e & f) ^ ((e ^ -1) & g)
        t1 = h + S1 + ch + s.k.get(i) + w.get(i)
        S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
        maj = (a & b) ^ (a & c) ^ (b & c)
        t2 = S0 + maj
        h = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
        i = i + 1
    }
    s.h.set(0, s.h.get(0) + a)
    s.h.set(1, s.h.get(1) + b)
    s.h.set(2, s.h.get(2) + c)
    s.h.set(3, s.h.get(3) + d)
    s.h.set(4, s.h.get(4) + e)
    s.h.set(5, s.h.get(5) + f)
    s.h.set(6, s.h.get(6) + g)
    s.h.set(7, s.h.get(7) + h)
}

public def sha512_update(s: @var Sha512, data: @Bytes) {
    s.total = s.total + data.len
    pos = 0
    if s.pending.len > 0 {
        while s.pending.len < 128 and pos < data.len {
            s.pending.push(data.get(pos))
            pos = pos + 1
        }
        if s.pending.len == 128 {
            sha512_compress_at(@var s, s.pending.data, 0)
            s.pending.len = 0
        }
    }
    while pos + 128 <= data.len {
        sha512_compress_at(@var s, data.data, pos)
        pos = pos + 128
    }
    while pos < data.len {
        s.pending.push(data.get(pos))
        pos = pos + 1
    }
}

public def sha512_finish(s: @var Sha512) -> Bytes {
    bits = s.total * 8
    s.pending.push(128)
    while s.pending.len % 128 != 112 {
        s.pending.push(0)
    }
    i = 0
    while i < 8 {
        s.pending.push(0)
        i = i + 1
    }
    i = 0
    while i < 8 {
        s.pending.push((bits >> (56 - i * 8)) & 255)
        i = i + 1
    }
    pos = 0
    while pos < s.pending.len {
        sha512_compress_at(@var s, s.pending.data, pos)
        pos = pos + 128
    }
    s.pending.len = 0
    out = bytes.bytes_new(s.out_len)
    i = 0
    while i < s.out_len / 8 {
        v = s.h.get(i)
        j = 0
        while j < 8 {
            out.push((v >> (56 - j * 8)) & 255)
            j = j + 1
        }
        i = i + 1
    }
    return out
}

public def sha512_digest(s: @Sha512) -> Bytes {
    c = sha512_clone(@s)
    return sha512_finish(@var c)
}

public def sha512(data: @Bytes) -> Bytes {
    s = sha512_new(64)
    sha512_update(@var s, data)
    return sha512_finish(@var s)
}

public def sha384(data: @Bytes) -> Bytes {
    s = sha384_new()
    sha512_update(@var s, data)
    return sha512_finish(@var s)
}
