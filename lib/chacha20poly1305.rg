# RGC standard library: chacha20poly1305
#
# Pure RGC ChaCha20 (RFC 8439) and ChaCha20-Poly1305 AEAD, covering the TLS 1.3
# TLS_CHACHA20_POLY1305_SHA256 cipher suite.
#
# Usage:
#   import chacha20poly1305 as chacha
#   sealed = chacha.seal(@key32, @nonce12, @aad, @plaintext)   # ciphertext || tag
#   r = chacha.open(@key32, @nonce12, @aad, @sealed)
#
# The Poly1305 core uses 26-bit limbs (donna-style) and i64 products.

import bytes
import bin

def le32(b: @Bytes, off: int) -> int {
    return b.get(off) | (b.get(off + 1) << 8) | (b.get(off + 2) << 16) |
           (b.get(off + 3) << 24)
}

def rotl32(x: int, n: int) -> int {
    return ((x << n) | (x >> (32 - n))) & 4294967295
}

def qr(st: @var List[int], a: int, b: int, c: int, d: int) {
    st.set(a, (st.get(a) + st.get(b)) & 4294967295)
    st.set(d, st.get(d) ^ st.get(a))
    st.set(d, rotl32(st.get(d), 16))
    st.set(c, (st.get(c) + st.get(d)) & 4294967295)
    st.set(b, st.get(b) ^ st.get(c))
    st.set(b, rotl32(st.get(b), 12))
    st.set(a, (st.get(a) + st.get(b)) & 4294967295)
    st.set(d, st.get(d) ^ st.get(a))
    st.set(d, rotl32(st.get(d), 8))
    st.set(c, (st.get(c) + st.get(d)) & 4294967295)
    st.set(b, st.get(b) ^ st.get(c))
    st.set(b, rotl32(st.get(b), 7))
}

public def chacha_block(key: @Bytes, counter: int, nonce: @Bytes) -> Bytes {
    init = List[int]()
    init.push(0x61707865)
    init.push(0x3320646e)
    init.push(0x79622d32)
    init.push(0x6b206574)
    i = 0
    while i < 8 {
        init.push(le32(key, i * 4))
        i = i + 1
    }
    init.push(counter & 4294967295)
    i = 0
    while i < 3 {
        init.push(le32(nonce, i * 4))
        i = i + 1
    }
    st = List[int]()
    i = 0
    while i < 16 {
        st.push(init.get(i))
        i = i + 1
    }
    r = 0
    while r < 10 {
        qr(@var st, 0, 4, 8, 12)
        qr(@var st, 1, 5, 9, 13)
        qr(@var st, 2, 6, 10, 14)
        qr(@var st, 3, 7, 11, 15)
        qr(@var st, 0, 5, 10, 15)
        qr(@var st, 1, 6, 11, 12)
        qr(@var st, 2, 7, 8, 13)
        qr(@var st, 3, 4, 9, 14)
        r = r + 1
    }
    out = bytes.bytes_new(64)
    i = 0
    while i < 16 {
        v = (st.get(i) + init.get(i)) & 4294967295
        out.push(v & 255)
        out.push((v >> 8) & 255)
        out.push((v >> 16) & 255)
        out.push((v >> 24) & 255)
        i = i + 1
    }
    return out
}

public def chacha20_xor(key: @Bytes, nonce: @Bytes, first_counter: int,
                        data: @Bytes) -> Bytes {
    out = bytes.bytes_new(data.len)
    pos = 0
    ctr = first_counter
    while pos < data.len {
        ks = chacha_block(key, ctr, nonce)
        n = data.len - pos
        if n > 64 {
            n = 64
        }
        i = 0
        while i < n {
            out.push(data.get(pos + i) ^ ks.get(i))
            i = i + 1
        }
        ctr = ctr + 1
        pos = pos + 64
    }
    return out
}

# ---------------------------------------------------------------------------
# Poly1305
# ---------------------------------------------------------------------------

public def poly1305(key: @Bytes, msg: @Bytes) -> Bytes {
    m26 = 67108863
    r0 = le32(key, 0) & m26
    r1 = (le32(key, 3) >> 2) & 0x3ffff03
    r2 = (le32(key, 6) >> 4) & 0x3ffc0ff
    r3 = (le32(key, 9) >> 6) & 0x3f03fff
    r4 = (le32(key, 12) >> 8) & 0x00fffff
    s1 = r1 * 5
    s2 = r2 * 5
    s3 = r3 * 5
    s4 = r4 * 5

    h0 = 0
    h1 = 0
    h2 = 0
    h3 = 0
    h4 = 0
    pos = 0
    while pos < msg.len {
        rem = msg.len - pos
        last = 0
        if rem >= 16 {
            rem = 16
            last = 1
        }
        blk = bytes.bytes_new(16)
        i = 0
        while i < 16 {
            blk.push(0)
            i = i + 1
        }
        i = 0
        while i < rem {
            blk.set(i, msg.get(pos + i))
            i = i + 1
        }
        if last == 0 {
            blk.set(rem, 1)
        }
        h0 = h0 + (le32(@blk, 0) & m26)
        h1 = h1 + ((le32(@blk, 3) >> 2) & m26)
        h2 = h2 + ((le32(@blk, 6) >> 4) & m26)
        h3 = h3 + ((le32(@blk, 9) >> 6) & m26)
        h4 = h4 + (le32(@blk, 12) >> 8)
        if last == 1 {
            h4 = h4 + 16777216
        }

        d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
        d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
        d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
        d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
        d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0

        c = d0 >> 26
        h0 = d0 & m26
        d1 = d1 + c
        c = d1 >> 26
        h1 = d1 & m26
        d2 = d2 + c
        c = d2 >> 26
        h2 = d2 & m26
        d3 = d3 + c
        c = d3 >> 26
        h3 = d3 & m26
        d4 = d4 + c
        c = d4 >> 26
        h4 = d4 & m26
        h0 = h0 + c * 5
        c = h0 >> 26
        h0 = h0 & m26
        h1 = h1 + c

        pos = pos + 16
    }

    c = h1 >> 26
    h1 = h1 & m26
    h2 = h2 + c
    c = h2 >> 26
    h2 = h2 & m26
    h3 = h3 + c
    c = h3 >> 26
    h3 = h3 & m26
    h4 = h4 + c
    c = h4 >> 26
    h4 = h4 & m26
    h0 = h0 + c * 5
    c = h0 >> 26
    h0 = h0 & m26
    h1 = h1 + c

    g0 = h0 + 5
    c = g0 >> 26
    g0 = g0 & m26
    g1 = h1 + c
    c = g1 >> 26
    g1 = g1 & m26
    g2 = h2 + c
    c = g2 >> 26
    g2 = g2 & m26
    g3 = h3 + c
    c = g3 >> 26
    g3 = g3 & m26
    g4 = h4 + c
    c = g4 >> 26
    g4 = g4 & m26
    if c != 0 {
        h0 = g0
        h1 = g1
        h2 = g2
        h3 = g3
        h4 = g4
    }

    w0 = (h0 | (h1 << 26)) & 4294967295
    w1 = ((h1 >> 6) | (h2 << 20)) & 4294967295
    w2 = ((h2 >> 12) | (h3 << 14)) & 4294967295
    w3 = ((h3 >> 18) | (h4 << 8)) & 4294967295

    f = w0 + le32(key, 16)
    o0 = f & 4294967295
    carry = f >> 32
    f = w1 + le32(key, 20) + carry
    o1 = f & 4294967295
    carry = f >> 32
    f = w2 + le32(key, 24) + carry
    o2 = f & 4294967295
    carry = f >> 32
    f = w3 + le32(key, 28) + carry
    o3 = f & 4294967295

    out = bytes.bytes_new(16)
    bin.put_u32(out, o0)
    bin.put_u32(out, o1)
    bin.put_u32(out, o2)
    bin.put_u32(out, o3)
    # bin.put_u32 is big-endian; Poly1305 tags are little-endian words.
    out2 = bytes.bytes_new(16)
    i = 0
    while i < 4 {
        v = out.get(i * 4 + 3)
        out2.push(v)
        out2.push(out.get(i * 4 + 2))
        out2.push(out.get(i * 4 + 1))
        out2.push(out.get(i * 4))
        i = i + 1
    }
    return out2
}

def pad16(out: @var Bytes, n: int) {
    r = n % 16
    if r != 0 {
        i = r
        while i < 16 {
            out.push(0)
            i = i + 1
        }
    }
}

def le64(v: int) -> Bytes {
    b = bytes.bytes_new(8)
    i = 0
    while i < 8 {
        b.push((v >> (i * 8)) & 255)
        i = i + 1
    }
    return b
}

def mac_input(aad: @Bytes, ct: @Bytes) -> Bytes {
    out = bytes.bytes_new(aad.len + ct.len + 32)
    out.append(aad)
    pad16(@var out, aad.len)
    out.append(ct)
    pad16(@var out, ct.len)
    al = le64(aad.len)
    cl = le64(ct.len)
    out.append(@al)
    out.append(@cl)
    return out
}

# ---------------------------------------------------------------------------
# AEAD
# ---------------------------------------------------------------------------

public class ChachaResult {
    ok: bool
    error: str
    data: Bytes
}

public def seal(key: @Bytes, nonce: @Bytes, aad: @Bytes,
                plaintext: @Bytes) -> Bytes {
    out = bytes.bytes_new(0)
    if key.len != 32 or nonce.len != 12 {
        return out
    }
    otk = chacha_block(key, 0, nonce)
    poly_key = otk.slice(0, 32)
    ct = chacha20_xor(key, nonce, 1, plaintext)
    mac_data = mac_input(aad, @ct)
    tag = poly1305(@poly_key, @mac_data)
    out = bytes.bytes_new(ct.len + 16)
    out.append(@ct)
    out.append(@tag)
    return out
}

public def open(key: @Bytes, nonce: @Bytes, aad: @Bytes,
                sealed: @Bytes) -> ChachaResult {
    r = ChachaResult()
    r.ok = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    if key.len != 32 or nonce.len != 12 {
        r.error = "invalid ChaCha20-Poly1305 key or nonce length"
        return r
    }
    if sealed.len < 16 {
        r.error = "ciphertext is shorter than the Poly1305 tag"
        return r
    }
    ct = sealed.slice(0, sealed.len - 16)
    tag = sealed.slice(sealed.len - 16, sealed.len)
    otk = chacha_block(key, 0, nonce)
    poly_key = otk.slice(0, 32)
    mac_data = mac_input(aad, @ct)
    expect = poly1305(@poly_key, @mac_data)
    if not bin.equal(@expect, @tag) {
        r.error = "Poly1305 tag mismatch"
        return r
    }
    r.data = chacha20_xor(key, nonce, 1, @ct)
    r.ok = True
    return r
}
