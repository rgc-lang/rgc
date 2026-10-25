# RGC standard library: x25519
#
# X25519 (RFC 7748) Diffie-Hellman over Curve25519, pure RGC on top of
# lib/bigint.rg Montgomery arithmetic. Used by the TLS 1.3 x25519 key share.
#
# Usage:
#   import x25519
#   kp = x25519.keypair()
#   shared = x25519.shared_secret(@kp.private_key, @peer_public)
#
# Notes:
#   - Public keys and shared secrets are 32-byte little-endian strings.
#   - The scalar-clamping and final u-mask rules from RFC 7748 are applied.
#   - The Montgomery ladder uses masked conditional swaps (no branch on the
#     secret scalar bits); field additions/subtractions use conditional
#     subtraction as usual.

import bytes
import bigint as bn
import entropy

public class X25519KeyPair {
    private_key: Bytes
    public_key: Bytes
}

public class X25519Ctx {
    p: Big
    mc: Mont
    a24: Big
}

def new_ctx() -> X25519Ctx {
    c = X25519Ctx()
    p = bn.from_hex("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed", 16)
    mc = bn.mont_new(@p)
    a = bn.big_from_int(121665, 16)
    c.p = p
    c.mc = mc
    c.a24 = bn.mont_from(@mc, @a)
    return c
}

def mm(mc: @Mont, a: @Big, b: @Big) -> Big {
    return bn.mont_mul(mc, @a, @b)
}

def cswap(a: @var Big, b: @var Big, bit: int) {
    mask = 0 - bit
    i = 0
    while i < a.n {
        x = a.d.get(i)
        y = b.d.get(i)
        diff = (x ^ y) & mask & 65535
        a.d.set(i, x ^ diff)
        b.d.set(i, y ^ diff)
        i = i + 1
    }
}

def clamp(k_in: @Bytes) -> Bytes {
    k = k_in.slice(0, 32)
    first = k.get(0) & 248
    last = (k.get(31) & 127) | 64
    k.set(0, first)
    k.set(31, last)
    return k
}

public def shared_secret(private_key: @Bytes, peer_public: @Bytes) -> Bytes {
    if private_key.len != 32 or peer_public.len != 32 {
        return bytes.bytes_new(0)
    }
    c = new_ctx()
    mc = c.mc
    kb = clamp(private_key)
    k = bn.big_from_bytes_le(@kb, 16)

    peer = peer_public.slice(0, 32)
    top = peer.get(31) & 127
    peer.set(31, top)
    ub = bn.big_from_bytes_le(@peer, 16)
    x1 = bn.mont_from(@mc, @ub)

    one_src = mc.one
    one = bn.big_copy(@one_src)
    zero = bn.big_new(16)
    x2 = bn.big_copy(@one)
    z2 = bn.big_copy(@zero)
    x3 = bn.big_copy(@x1)
    z3 = bn.big_copy(@one)
    a24 = c.a24

    swap = 0
    t = 254
    while t >= 0 {
        kt = bn.big_bit(@k, t)
        swap = swap ^ kt
        cswap(@var x2, @var x3, swap)
        cswap(@var z2, @var z3, swap)
        swap = kt

        a = bn.mont_add(@mc, @x2, @z2)
        aa = mm(@mc, @a, @a)
        b = bn.mont_sub(@mc, @x2, @z2)
        bb = mm(@mc, @b, @b)
        e = bn.mont_sub(@mc, @aa, @bb)
        cc = bn.mont_add(@mc, @x3, @z3)
        d = bn.mont_sub(@mc, @x3, @z3)
        da = mm(@mc, @d, @a)
        cb = mm(@mc, @cc, @b)
        s = bn.mont_add(@mc, @da, @cb)
        x3 = mm(@mc, @s, @s)
        tmp = bn.mont_sub(@mc, @da, @cb)
        tmp = mm(@mc, @tmp, @tmp)
        z3 = mm(@mc, @x1, @tmp)
        x2 = mm(@mc, @aa, @bb)
        ae = mm(@mc, @a24, @e)
        tmp2 = bn.mont_add(@mc, @aa, @ae)
        z2 = mm(@mc, @e, @tmp2)

        t = t - 1
    }
    cswap(@var x2, @var x3, swap)
    cswap(@var z2, @var z3, swap)

    invz = bn.mont_inv(@mc, @z2)
    res = mm(@mc, @x2, @invz)
    plain = bn.mont_to(@mc, @res)
    return bn.big_to_bytes_le(@plain, 32)
}

public def base_public(private_key: @Bytes) -> Bytes {
    base = bytes.bytes_new(32)
    base.push(9)
    i = 1
    while i < 32 {
        base.push(0)
        i = i + 1
    }
    return shared_secret(private_key, @base)
}

public def keypair() -> X25519KeyPair {
    kp = X25519KeyPair()
    kp.private_key = entropy.bytes_random(32)
    kp.public_key = bytes.bytes_new(0)
    if kp.private_key.len == 32 {
        pk = kp.private_key
        kp.public_key = base_public(@pk)
    }
    return kp
}
