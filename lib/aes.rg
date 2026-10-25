# RGC standard library: aes
#
# Pure RGC AES-128/AES-256 block encryption plus AES-GCM AEAD (NIST SP 800-38D),
# covering the TLS 1.3 TLS_AES_128_GCM_SHA256 and TLS_AES_256_GCM_SHA384 suites.
#
# Usage:
#   import aes
#   sealed = aes.gcm_seal(@key, @nonce12, @aad, @plaintext)   # ciphertext || tag
#   r = aes.gcm_open(@key, @nonce12, @aad, @sealed)
#   if r.ok { print(r.data.len) }
#
# Notes:
#   - The S-box is derived from the GF(2^8) inverse plus the affine transform,
#     so there is no 256-entry literal table to mistype.
#   - GHASH multiplication is table-free and uses masks instead of data branches.
#   - Only encryption is needed for GCM/CTR; decryption is CTR with the same keystream.

import bytes
import bin

def gf_mul8(a: int, b: int) -> int {
    p = 0
    x = a
    y = b
    i = 0
    while i < 8 {
        if y & 1 != 0 {
            p = p ^ x
        }
        hi = x & 128
        x = (x << 1) & 255
        if hi != 0 {
            x = x ^ 27
        }
        y = y >> 1
        i = i + 1
    }
    return p
}

def gf_inv8(a: int) -> int {
    if a == 0 {
        return 0
    }
    result = 1
    base = a
    e = 254
    while e > 0 {
        if e & 1 != 0 {
            result = gf_mul8(result, base)
        }
        base = gf_mul8(base, base)
        e = e >> 1
    }
    return result
}

def rotl8(x: int, n: int) -> int {
    return ((x << n) | (x >> (8 - n))) & 255
}

def aes_sbox() -> List[int] {
    k = List[int]()
    i = 0
    while i < 256 {
        inv = gf_inv8(i)
        v = inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^
            rotl8(inv, 4) ^ 0x63
        k.push(v & 255)
        i = i + 1
    }
    return k
}

def xtime(x: int) -> int {
    return ((x << 1) ^ (27 & (0 - ((x >> 7) & 1)))) & 255
}

public class AesCtx {
    nr: int
    rk: List[int]
    sbox: List[int]
}

def sub_word(w: int, box: @List[int]) -> int {
    b0 = box.get((w >> 24) & 255)
    b1 = box.get((w >> 16) & 255)
    b2 = box.get((w >> 8) & 255)
    b3 = box.get(w & 255)
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

public def aes_new(key: @Bytes) -> AesCtx {
    c = AesCtx()
    c.sbox = aes_sbox()
    nk = key.len / 4
    c.nr = nk + 6
    c.rk = List[int]()
    i = 0
    while i < nk {
        c.rk.push((key.get(i * 4) << 24) | (key.get(i * 4 + 1) << 16) |
                  (key.get(i * 4 + 2) << 8) | key.get(i * 4 + 3))
        i = i + 1
    }
    total = 4 * (c.nr + 1)
    box = c.sbox
    rcon = 1
    while i < total {
        temp = c.rk.get(i - 1)
        if i % nk == 0 {
            temp = ((temp << 8) | ((temp >> 24) & 255)) & 4294967295
            temp = sub_word(temp, @box) ^ (rcon << 24)
            rcon = xtime(rcon)
        } elif nk > 6 and i % nk == 4 {
            temp = sub_word(temp, @box)
        }
        c.rk.push(c.rk.get(i - nk) ^ temp)
        i = i + 1
    }
    return c
}

def add_round_key(st: @var List[int], rk: @List[int], rnd: int) {
    c = 0
    while c < 4 {
        w = rk.get(rnd * 4 + c)
        st.set(c * 4, st.get(c * 4) ^ ((w >> 24) & 255))
        st.set(c * 4 + 1, st.get(c * 4 + 1) ^ ((w >> 16) & 255))
        st.set(c * 4 + 2, st.get(c * 4 + 2) ^ ((w >> 8) & 255))
        st.set(c * 4 + 3, st.get(c * 4 + 3) ^ (w & 255))
        c = c + 1
    }
}

def sub_bytes(st: @var List[int], box: @List[int]) {
    i = 0
    while i < 16 {
        st.set(i, box.get(st.get(i)))
        i = i + 1
    }
}

def shift_rows(st: @var List[int]) {
    old = List[int]()
    i = 0
    while i < 16 {
        old.push(st.get(i))
        i = i + 1
    }
    r = 0
    while r < 4 {
        c = 0
        while c < 4 {
            st.set(c * 4 + r, old.get(((c + r) % 4) * 4 + r))
            c = c + 1
        }
        r = r + 1
    }
}

def mix_columns(st: @var List[int]) {
    c = 0
    while c < 4 {
        a0 = st.get(c * 4)
        a1 = st.get(c * 4 + 1)
        a2 = st.get(c * 4 + 2)
        a3 = st.get(c * 4 + 3)
        t = a0 ^ a1 ^ a2 ^ a3
        st.set(c * 4, a0 ^ t ^ xtime(a0 ^ a1))
        st.set(c * 4 + 1, a1 ^ t ^ xtime(a1 ^ a2))
        st.set(c * 4 + 2, a2 ^ t ^ xtime(a2 ^ a3))
        st.set(c * 4 + 3, a3 ^ t ^ xtime(a3 ^ a0))
        c = c + 1
    }
}

public def aes_encrypt_block(ctx: @AesCtx, input: @Bytes) -> Bytes {
    rk = ctx.rk
    box = ctx.sbox
    st = List[int]()
    i = 0
    while i < 16 {
        st.push(input.get(i))
        i = i + 1
    }
    add_round_key(@var st, @rk, 0)
    rnd = 1
    while rnd < ctx.nr {
        sub_bytes(@var st, @box)
        shift_rows(@var st)
        mix_columns(@var st)
        add_round_key(@var st, @rk, rnd)
        rnd = rnd + 1
    }
    sub_bytes(@var st, @box)
    shift_rows(@var st)
    add_round_key(@var st, @rk, ctx.nr)
    out = bytes.bytes_new(16)
    i = 0
    while i < 16 {
        out.push(st.get(i))
        i = i + 1
    }
    return out
}

# ---------------------------------------------------------------------------
# GCM
# ---------------------------------------------------------------------------

public class GcmResult {
    ok: bool
    error: str
    data: Bytes
}

def zero_words() -> List[int] {
    w = List[int]()
    w.push(0)
    w.push(0)
    w.push(0)
    w.push(0)
    return w
}

def block_words(b: @Bytes, off: int) -> List[int] {
    w = List[int]()
    w.push(bin.u32(b, off))
    w.push(bin.u32(b, off + 4))
    w.push(bin.u32(b, off + 8))
    w.push(bin.u32(b, off + 12))
    return w
}

def words_block(w: @List[int]) -> Bytes {
    b = bytes.bytes_new(16)
    bin.put_u32(b, w.get(0))
    bin.put_u32(b, w.get(1))
    bin.put_u32(b, w.get(2))
    bin.put_u32(b, w.get(3))
    return b
}

def ghash_h(ctx: @AesCtx) -> List[int] {
    z = bytes.bytes_new(16)
    i = 0
    while i < 16 {
        z.push(0)
        i = i + 1
    }
    hb = aes_encrypt_block(ctx, @z)
    return block_words(@hb, 0)
}

def ghash_mul(x: @List[int], y: @List[int]) -> List[int] {
    z = zero_words()
    v = List[int]()
    v.push(y.get(0))
    v.push(y.get(1))
    v.push(y.get(2))
    v.push(y.get(3))
    i = 0
    while i < 128 {
        bit = (x.get(i / 32) >> (31 - (i % 32))) & 1
        m = 0 - bit
        z.set(0, z.get(0) ^ (v.get(0) & m))
        z.set(1, z.get(1) ^ (v.get(1) & m))
        z.set(2, z.get(2) ^ (v.get(2) & m))
        z.set(3, z.get(3) ^ (v.get(3) & m))
        lsb = v.get(3) & 1
        lm = 0 - lsb
        v.set(3, (v.get(3) >> 1) | ((v.get(2) & 1) << 31))
        v.set(2, (v.get(2) >> 1) | ((v.get(1) & 1) << 31))
        v.set(1, (v.get(1) >> 1) | ((v.get(0) & 1) << 31))
        v.set(0, (v.get(0) >> 1) ^ (0xe1000000 & lm))
        i = i + 1
    }
    return z
}

def ghash_block(y: @List[int], h: @List[int], b: @Bytes, off: int) -> List[int] {
    x = zero_words()
    x.set(0, y.get(0) ^ bin.u32(b, off))
    x.set(1, y.get(1) ^ bin.u32(b, off + 4))
    x.set(2, y.get(2) ^ bin.u32(b, off + 8))
    x.set(3, y.get(3) ^ bin.u32(b, off + 12))
    return ghash_mul(@x, h)
}

# Hash n bytes starting at off; a partial final block is zero-padded.
def ghash_segment(y: @List[int], h: @List[int], data: @Bytes, off: int,
                  n: int) -> List[int] {
    cur = zero_words()
    cur.set(0, y.get(0))
    cur.set(1, y.get(1))
    cur.set(2, y.get(2))
    cur.set(3, y.get(3))
    pos = 0
    while pos + 16 <= n {
        cur = ghash_block(@cur, h, data, off + pos)
        pos = pos + 16
    }
    if pos < n {
        blk = bytes.bytes_new(16)
        i = 0
        while i < 16 {
            blk.push(0)
            i = i + 1
        }
        i = 0
        while pos + i < n {
            blk.set(i, data.get(off + pos + i))
            i = i + 1
        }
        cur = ghash_block(@cur, h, @blk, 0)
    }
    return cur
}

def ghash_lengths(y: @List[int], h: @List[int], aad_len: int,
                   ct_len: int) -> List[int] {
    b = bytes.bytes_new(16)
    bin.put_u64(b, aad_len * 8)
    bin.put_u64(b, ct_len * 8)
    return ghash_block(y, h, @b, 0)
}

def inc32(w: @List[int]) -> List[int] {
    out = List[int]()
    out.push(w.get(0))
    out.push(w.get(1))
    out.push(w.get(2))
    out.push((w.get(3) + 1) & 4294967295)
    return out
}

def gcm_j0(h: @List[int], nonce: @Bytes) -> List[int] {
    if nonce.len == 12 {
        w = List[int]()
        w.push(bin.u32(nonce, 0))
        w.push(bin.u32(nonce, 4))
        w.push(bin.u32(nonce, 8))
        w.push(1)
        return w
    }
    zero = zero_words()
    y = ghash_segment(@zero, h, nonce, 0, nonce.len)
    b = bytes.bytes_new(16)
    bin.put_u64(b, 0)
    bin.put_u64(b, nonce.len * 8)
    return ghash_block(@y, h, @b, 0)
}

def tag_words(y: @List[int], ctx: @AesCtx, j0: @List[int]) -> Bytes {
    jb = words_block(j0)
    eb = aes_encrypt_block(ctx, @jb)
    e = block_words(@eb, 0)
    out = bytes.bytes_new(16)
    bin.put_u32(out, y.get(0) ^ e.get(0))
    bin.put_u32(out, y.get(1) ^ e.get(1))
    bin.put_u32(out, y.get(2) ^ e.get(2))
    bin.put_u32(out, y.get(3) ^ e.get(3))
    return out
}

def ctr_xor(ctx: @AesCtx, j0: @List[int], data: @Bytes) -> Bytes {
    out = bytes.bytes_new(data.len)
    ctr = inc32(j0)
    pos = 0
    while pos < data.len {
        cb = words_block(@ctr)
        ks = aes_encrypt_block(ctx, @cb)
        n = data.len - pos
        if n > 16 {
            n = 16
        }
        i = 0
        while i < n {
            out.push(data.get(pos + i) ^ ks.get(i))
            i = i + 1
        }
        ctr = inc32(@ctr)
        pos = pos + 16
    }
    return out
}

def gcm_valid_key(key: @Bytes) -> bool {
    return key.len == 16 or key.len == 32
}

# Returns ciphertext followed by the 16-byte tag.
public def gcm_seal(key: @Bytes, nonce: @Bytes, aad: @Bytes,
                    plaintext: @Bytes) -> Bytes {
    out = bytes.bytes_new(0)
    if not gcm_valid_key(key) {
        return out
    }
    ctx = aes_new(key)
    h = ghash_h(@ctx)
    j0 = gcm_j0(@h, nonce)
    z = zero_words()
    y = ghash_segment(@z, @h, aad, 0, aad.len)
    ct = ctr_xor(@ctx, @j0, plaintext)
    y2 = ghash_segment(@y, @h, @ct, 0, ct.len)
    y3 = ghash_lengths(@y2, @h, aad.len, ct.len)
    tag = tag_words(@y3, @ctx, @j0)
    out = bytes.bytes_new(ct.len + 16)
    out.append(@ct)
    out.append(@tag)
    return out
}

public def gcm_open(key: @Bytes, nonce: @Bytes, aad: @Bytes,
                    sealed: @Bytes) -> GcmResult {
    r = GcmResult()
    r.ok = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    if not gcm_valid_key(key) {
        r.error = "invalid AES key length"
        return r
    }
    if sealed.len < 16 {
        r.error = "ciphertext is shorter than the GCM tag"
        return r
    }
    ct = sealed.slice(0, sealed.len - 16)
    tag = sealed.slice(sealed.len - 16, sealed.len)
    ctx = aes_new(key)
    h = ghash_h(@ctx)
    j0 = gcm_j0(@h, nonce)
    z = zero_words()
    y = ghash_segment(@z, @h, aad, 0, aad.len)
    y2 = ghash_segment(@y, @h, @ct, 0, ct.len)
    y3 = ghash_lengths(@y2, @h, aad.len, ct.len)
    expect = tag_words(@y3, @ctx, @j0)
    if not bin.equal(@expect, @tag) {
        r.error = "GCM tag mismatch"
        return r
    }
    r.data = ctr_xor(@ctx, @j0, @ct)
    r.ok = True
    return r
}
