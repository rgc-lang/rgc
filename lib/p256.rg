# RGC standard library: p256
#
# NIST P-256 (secp256r1): ECDH key exchange and ECDSA signatures, pure RGC on
# top of lib/bigint.rg Montgomery arithmetic. Used by TLS 1.3 secp256r1 key
# shares, certificate ECDSA verification and client-certificate signing.
#
# Usage:
#   import p256
#   kp = p256.keypair()
#   pub = p256.base_public(@kp.private_key)       # 65-byte uncompressed point
#   shared = p256.shared_secret(@kp.private_key, @peer_pub)
#   ok = p256.ecdsa_verify_hash(@cert_pub, @hash, @der_sig)
#   sig = p256.ecdsa_sign_hash(@kp.private_key, @hash)
#
# Notes:
#   - Points are kept in Jacobian coordinates in the Montgomery domain; the
#     public API uses affine uncompressed (0x04||X||Y) or compressed
#     (0x02/0x03||X) encodings on the wire.
#   - Scalar multiplication is plain MSB-first double-and-add and is not
#     constant-time; do not expose it to timing measurements of long-term keys.
#   - ECDSA signatures are DER ECDSA-Sig-Value, normalized to low-S.

import bytes
import bigint as bn
import entropy

public class P256Ctx {
    mc: Mont
    b: Big
    n: Big
    mn: Mont
    gx: Big
    gy: Big
    sqrt_exp: Big
    sb: int                            # scalar/field byte width: 32 (P-256) or 48 (P-384)
}

public class P256Point {
    x: Big
    y: Big
    z: Big
}

public class P256Affine {
    x: Big
    y: Big
}

public class P256PointResult {
    ok: bool
    error: str
    point: P256Point
}

public class P256KeyPair {
    private_key: Bytes
    public_key: Bytes
}

public class P256Sig {
    ok: bool
    r: Big
    s: Big
}

def fmul(mc: @Mont, a: @Big, b: @Big) -> Big {
    return bn.mont_mul(mc, @a, @b)
}

def fsqr(mc: @Mont, a: @Big) -> Big {
    return bn.mont_mul(mc, @a, @a)
}

def fadd(mc: @Mont, a: @Big, b: @Big) -> Big {
    return bn.mont_add(mc, @a, @b)
}

def fsub(mc: @Mont, a: @Big, b: @Big) -> Big {
    return bn.mont_sub(mc, @a, @b)
}

def f3(mc: @Mont, a: @Big) -> Big {
    d = fadd(mc, @a, @a)
    return fadd(mc, @d, @a)
}

def f4(mc: @Mont, a: @Big) -> Big {
    d = fadd(mc, @a, @a)
    return fadd(mc, @d, @d)
}

def f8(mc: @Mont, a: @Big) -> Big {
    d = fadd(mc, @a, @a)
    e = fadd(mc, @d, @d)
    return fadd(mc, @e, @e)
}

def point_make(x: Big, y: Big, z: Big) -> P256Point {
    p = P256Point()
    p.x = x
    p.y = y
    p.z = z
    return p
}

def point_zero(mc: @Mont) -> P256Point {
    lb = mc.n
    x0 = bn.big_new(lb)
    y0 = bn.big_new(lb)
    z0 = bn.big_new(lb)
    return point_make(x0, y0, z0)
}

def point_copy(p: @P256Point) -> P256Point {
    x = p.x
    y = p.y
    z = p.z
    return point_make(bn.big_copy(@x), bn.big_copy(@y), bn.big_copy(@z))
}

public def point_is_infinity(p: @P256Point) -> bool {
    z = p.z
    return bn.big_is_zero(@z)
}

public def ctx_new() -> P256Ctx {
    c = P256Ctx()
    p = bn.from_hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    c.mc = bn.mont_new(@p)
    mc = c.mc
    b0 = bn.from_hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    c.b = bn.mont_from(@mc, @b0)
    n = bn.from_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
    c.mn = bn.mont_new(@n)
    c.n = n
    gx = bn.from_hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296", 16)
    gy = bn.from_hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", 16)
    c.gx = bn.mont_from(@mc, @gx)
    c.gy = bn.mont_from(@mc, @gy)
    c.sqrt_exp = bn.from_hex("3fffffffc0000000400000000000000000000000400000000000000000000000", 16)
    c.sb = 32
    return c
}

# NIST P-384 (secp384r1): same curve shape (a = -3), verification-only users pass
# this context to parse_public_ctx / ecdsa_verify_hash_ctx.
public def ctx_new_p384() -> P256Ctx {
    c = P256Ctx()
    p = bn.from_hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff", 24)
    c.mc = bn.mont_new(@p)
    mc = c.mc
    b0 = bn.from_hex("b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef", 24)
    c.b = bn.mont_from(@mc, @b0)
    n = bn.from_hex("ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973", 24)
    c.mn = bn.mont_new(@n)
    c.n = n
    gx = bn.from_hex("aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7", 24)
    gy = bn.from_hex("3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f", 24)
    c.gx = bn.mont_from(@mc, @gx)
    c.gy = bn.mont_from(@mc, @gy)
    c.sqrt_exp = bn.from_hex("3fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbfffffffc00000000000000040000000", 24)
    c.sb = 48
    return c
}

def point_from_affine(mc: @Mont, x: @Big, y: @Big) -> P256Point {
    xm = bn.mont_from(mc, @x)
    ym = bn.mont_from(mc, @y)
    one_src = mc.one
    z = bn.big_copy(@one_src)
    return point_make(xm, ym, z)
}

public def point_to_affine(mc: @Mont, p: @P256Point) -> P256Affine {
    a = P256Affine()
    a.x = bn.big_new(mc.n)
    a.y = bn.big_new(mc.n)
    z = p.z
    if bn.big_is_zero(@z) {
        return a
    }
    x = p.x
    y = p.y
    zinv = bn.mont_inv(mc, @z)
    zinv2 = fsqr(mc, @zinv)
    ax = fmul(mc, @x, @zinv2)
    zinv3 = fmul(mc, @zinv2, @zinv)
    ay = fmul(mc, @y, @zinv3)
    a.x = bn.mont_to(mc, @ax)
    a.y = bn.mont_to(mc, @ay)
    return a
}

def point_double(mc: @Mont, p: @P256Point) -> P256Point {
    z = p.z
    if bn.big_is_zero(@z) {
        return point_zero(mc)
    }
    x = p.x
    y = p.y
    delta = fsqr(mc, @z)
    gamma = fsqr(mc, @y)
    beta = fmul(mc, @x, @gamma)
    t1 = fsub(mc, @x, @delta)
    t2 = fadd(mc, @x, @delta)
    alpha = fmul(mc, @t1, @t2)
    alpha3 = f3(mc, @alpha)
    x3 = fsqr(mc, @alpha3)
    beta8 = f8(mc, @beta)
    x3 = fsub(mc, @x3, @beta8)
    yz = fadd(mc, @y, @z)
    z3 = fsqr(mc, @yz)
    z3 = fsub(mc, @z3, @gamma)
    z3 = fsub(mc, @z3, @delta)
    beta4 = f4(mc, @beta)
    t3 = fsub(mc, @beta4, @x3)
    y3 = fmul(mc, @alpha3, @t3)
    gamma2 = fsqr(mc, @gamma)
    gamma8 = f8(mc, @gamma2)
    y3 = fsub(mc, @y3, @gamma8)
    return point_make(x3, y3, z3)
}

def point_add(mc: @Mont, p: @P256Point, q: @P256Point) -> P256Point {
    z1 = p.z
    z2 = q.z
    if bn.big_is_zero(@z1) {
        return point_copy(q)
    }
    if bn.big_is_zero(@z2) {
        return point_copy(p)
    }
    x1 = p.x
    y1 = p.y
    x2 = q.x
    y2 = q.y
    z1z1 = fsqr(mc, @z1)
    z2z2 = fsqr(mc, @z2)
    u1 = fmul(mc, @x1, @z2z2)
    u2 = fmul(mc, @x2, @z1z1)
    s1 = fmul(mc, @y1, @z2)
    s1 = fmul(mc, @s1, @z2z2)
    s2 = fmul(mc, @y2, @z1)
    s2 = fmul(mc, @s2, @z1z1)
    h = fsub(mc, @u2, @u1)
    r = fsub(mc, @s2, @s1)
    r = fadd(mc, @r, @r)
    if bn.big_is_zero(@h) {
        if bn.big_is_zero(@r) {
            return point_double(mc, p)
        }
        return point_zero(mc)
    }
    i = fadd(mc, @h, @h)
    i = fsqr(mc, @i)
    j = fmul(mc, @h, @i)
    v = fmul(mc, @u1, @i)
    x3 = fsqr(mc, @r)
    x3 = fsub(mc, @x3, @j)
    v2 = fadd(mc, @v, @v)
    x3 = fsub(mc, @x3, @v2)
    t = fsub(mc, @v, @x3)
    y3 = fmul(mc, @r, @t)
    s1j = fmul(mc, @s1, @j)
    s1j = fadd(mc, @s1j, @s1j)
    y3 = fsub(mc, @y3, @s1j)
    zs = fadd(mc, @z1, @z2)
    zt = fsqr(mc, @zs)
    zt = fsub(mc, @zt, @z1z1)
    zt = fsub(mc, @zt, @z2z2)
    z3 = fmul(mc, @zt, @h)
    return point_make(x3, y3, z3)
}

def scalar_mul(mc: @Mont, k: @Big, p: @P256Point) -> P256Point {
    r = point_zero(mc)
    bits = bn.big_bit_len(@k)
    i = bits - 1
    while i >= 0 {
        r = point_double(mc, @r)
        if bn.big_bit(@k, i) != 0 {
            r = point_add(mc, @r, p)
        }
        i = i - 1
    }
    return r
}

def point_base(mc: @Mont, gx: @Big, gy: @Big) -> P256Point {
    one_src = mc.one
    z = bn.big_copy(@one_src)
    return point_make(bn.big_copy(@gx), bn.big_copy(@gy), z)
}

def on_curve(mc: @Mont, b: @Big, x: @Big, y: @Big) -> bool {
    xm = bn.mont_from(mc, @x)
    ym = bn.mont_from(mc, @y)
    lhs = fsqr(mc, @ym)
    xsq = fsqr(mc, @xm)
    x3 = fmul(mc, @xsq, @xm)
    rx = f3(mc, @xm)
    rhs = fsub(mc, @x3, @rx)
    rhs = fadd(mc, @rhs, b)
    return bn.big_cmp(@lhs, @rhs) == 0
}

def field_sqrt(mc: @Mont, a: @Big, e: @Big) -> Big {
    return bn.mont_pow(mc, a, @e)
}

def parse_raw(mc: @Mont, b: @Big, sqrt_exp: @Big, data: @Bytes) -> P256PointResult {
    out = P256PointResult()
    out.ok = False
    out.error = ""
    out.point = point_zero(mc)
    pm = mc.m
    flen = (bn.big_bit_len(@pm) + 7) / 8
    lb = mc.n
    n = data.len
    if n == 1 + 2 * flen and data.get(0) == 4 {
        xb = data.slice(1, 1 + flen)
        yb = data.slice(1 + flen, 1 + 2 * flen)
        x = bn.big_from_bytes_be(@xb, lb)
        y = bn.big_from_bytes_be(@yb, lb)
        if not on_curve(mc, @b, @x, @y) {
            out.error = "point is not on curve"
            return out
        }
        out.ok = True
        out.point = point_from_affine(mc, @x, @y)
        return out
    }
    if n == 1 + flen and (data.get(0) == 2 or data.get(0) == 3) {
        xb = data.slice(1, 1 + flen)
        x = bn.big_from_bytes_be(@xb, lb)
        xm = bn.mont_from(mc, @x)
        xsq = fsqr(mc, @xm)
        x3 = fmul(mc, @xsq, @xm)
        rx = f3(mc, @xm)
        rhs = fsub(mc, @x3, @rx)
        rhs = fadd(mc, @rhs, b)
        ym = field_sqrt(mc, @rhs, @sqrt_exp)
        ysq = fsqr(mc, @ym)
        if bn.big_cmp(@ysq, @rhs) != 0 {
            out.error = "point is not on curve"
            return out
        }
        y = bn.mont_to(mc, @ym)
        want_odd = 0
        if data.get(0) == 3 {
            want_odd = 1
        }
        got_odd = y.d.get(0) & 1
        if got_odd != want_odd {
            pmod = mc.m
            y = bn.big_sub_mod(@pmod, @y, @pmod)
        }
        out.ok = True
        out.point = point_from_affine(mc, @x, @y)
        return out
    }
    out.error = "unsupported point encoding"
    return out
}

public def parse_public(data: @Bytes) -> P256PointResult {
    return parse_public_ctx(ctx_new(), data)
}

public def parse_public_ctx(ctx: @P256Ctx, data: @Bytes) -> P256PointResult {
    mc = ctx.mc
    b = ctx.b
    e = ctx.sqrt_exp
    return parse_raw(mc, @b, @e, data)
}

public def encode_public(p: @P256Point) -> Bytes {
    ctx = ctx_new()
    mc = ctx.mc
    return encode_point(mc, p)
}

def encode_point(mc: @Mont, p: @P256Point) -> Bytes {
    a = point_to_affine(mc, p)
    pm = mc.m
    flen = (bn.big_bit_len(@pm) + 7) / 8
    out = bytes.bytes_new(1 + 2 * flen)
    out.push(4)
    ax = a.x
    ay = a.y
    xb = bn.big_to_bytes_be(@ax, flen)
    yb = bn.big_to_bytes_be(@ay, flen)
    out.append_mem(xb.data, xb.len)
    out.append_mem(yb.data, yb.len)
    return out
}

# Private scalars must be in [1, n-1]; a raw 32-byte big-endian scalar is used.
def valid_private(n: @Big, d: @Big) -> bool {
    one = bn.big_from_int(1, 16)
    if bn.big_cmp(@d, @one) < 0 {
        return False
    }
    return bn.big_cmp(@d, n) < 0
}

public def base_public(private_key: @Bytes) -> Bytes {
    if private_key.len != 32 {
        return bytes.bytes_new(0)
    }
    ctx = ctx_new()
    mc = ctx.mc
    n = ctx.n
    gx = ctx.gx
    gy = ctx.gy
    d = bn.big_from_bytes_be(private_key, mc.n)
    if not valid_private(@n, @d) {
        return bytes.bytes_new(0)
    }
    g = point_base(mc, @gx, @gy)
    q = scalar_mul(mc, @d, @g)
    return encode_point(mc, @q)
}

public def shared_secret(private_key: @Bytes, peer_public: @Bytes) -> Bytes {
    if private_key.len != 32 {
        return bytes.bytes_new(0)
    }
    ctx = ctx_new()
    mc = ctx.mc
    b = ctx.b
    n = ctx.n
    e = ctx.sqrt_exp
    d = bn.big_from_bytes_be(private_key, 16)
    if not valid_private(@n, @d) {
        return bytes.bytes_new(0)
    }
    pr = parse_raw(mc, @b, @e, peer_public)
    if not pr.ok {
        return bytes.bytes_new(0)
    }
    qp = pr.point
    q = scalar_mul(mc, @d, @qp)
    if point_is_infinity(@q) {
        return bytes.bytes_new(0)
    }
    a = point_to_affine(mc, @q)
    ax = a.x
    return bn.big_to_bytes_be(@ax, 32)
}

public def keypair() -> P256KeyPair {
    kp = P256KeyPair()
    kp.private_key = entropy.bytes_random(32)
    kp.public_key = bytes.bytes_new(0)
    guard = 0
    while guard < 8 and kp.public_key.len == 0 {
        if kp.private_key.len == 32 {
            priv = kp.private_key
            pub = base_public(@priv)
            kp.public_key = pub
        }
        if kp.public_key.len == 0 {
            kp.private_key = entropy.bytes_random(32)
        }
        guard = guard + 1
    }
    return kp
}

# ---------------------------------------------------------------------------
# ECDSA (SHA-256/384/512 digests are passed in already hashed)
# ---------------------------------------------------------------------------

def hash_to_scalar(n: @Big, hash: @Bytes) -> Big {
    ln = (bn.big_bit_len(@n) + 7) / 8
    if hash.len < ln {
        ln = hash.len
    }
    hb = hash.slice(0, ln)
    e = bn.big_from_bytes_be(@hb, n.n)
    if bn.big_cmp(@e, n) >= 0 {
        e = bn.big_sub_mod(@e, n, n)
    }
    return e
}

public def der_parse_sig(sig: @Bytes) -> P256Sig {
    return der_parse_sig_w(sig, 32)
}

def der_parse_sig_w(sig: @Bytes, sb: int) -> P256Sig {
    lb = sb / 2
    out = P256Sig()
    out.ok = False
    out.r = bn.big_new(lb)
    out.s = bn.big_new(lb)
    if sig.len < 8 or sig.get(0) != 48 {
        return out
    }
    total = sig.get(1)
    if total + 2 > sig.len or total < 6 {
        return out
    }
    if sig.get(2) != 2 {
        return out
    }
    rl = sig.get(3)
    if rl < 1 or rl > sb + 1 or 6 + rl > sig.len {
        return out
    }
    p2 = 4 + rl
    if sig.get(p2) != 2 {
        return out
    }
    sl = sig.get(p2 + 1)
    if sl < 1 or sl > sb + 1 or p2 + 2 + sl > sig.len {
        return out
    }
    rb = sig.slice(4, 4 + rl)
    sbts = sig.slice(p2 + 2, p2 + 2 + sl)
    r = der_int_value(@rb, lb)
    s = der_int_value(@sbts, lb)
    out.ok = True
    out.r = r
    out.s = s
    return out
}

def der_int_value(v: @Bytes, lb: int) -> Big {
    start = 0
    if v.len > 0 and v.get(0) == 0 {
        start = 1
    }
    body = v.slice(start, v.len)
    return bn.big_from_bytes_be(@body, lb)
}

def der_int_encode_w(v: @Big, sb: int) -> Bytes {
    full = bn.big_to_bytes_be(v, sb)
    i = 0
    while i < sb - 1 and full.get(i) == 0 {
        i = i + 1
    }
    body = full.slice(i, sb)
    out = bytes.bytes_new(sb + 3)
    out.push(2)
    if (body.get(0) & 128) != 0 {
        out.push(body.len + 1)
        out.push(0)
    } else {
        out.push(body.len)
    }
    out.append_mem(body.data, body.len)
    return out
}

public def der_encode_sig(r: @Big, s: @Big) -> Bytes {
    return der_encode_sig_w(@r, @s, 32)
}

def der_encode_sig_w(r: @Big, s: @Big, sb: int) -> Bytes {
    rb = der_int_encode_w(@r, sb)
    sbts = der_int_encode_w(@s, sb)
    out = bytes.bytes_new(rb.len + sbts.len + 2)
    out.push(48)
    out.push(rb.len + sbts.len)
    out.append_mem(rb.data, rb.len)
    out.append_mem(sbts.data, sbts.len)
    return out
}

def ecdsa_verify_raw(mc: @Mont, n: @Big, mn: @Mont, gx: @Big, gy: @Big,
                     pub: @P256Point, hash: @Bytes, sig: @Bytes) -> bool {
    sb = (bn.big_bit_len(n) + 7) / 8
    rs = der_parse_sig_w(sig, sb)
    if not rs.ok {
        return False
    }
    r = rs.r
    s = rs.s
    one = bn.big_from_int(1, 16)
    if bn.big_cmp(@r, @one) < 0 or bn.big_cmp(@r, n) >= 0 {
        return False
    }
    if bn.big_cmp(@s, @one) < 0 or bn.big_cmp(@s, n) >= 0 {
        return False
    }
    e = hash_to_scalar(n, hash)
    sm = bn.mont_from(mn, @s)
    w = bn.mont_inv(mn, @sm)
    em = bn.mont_from(mn, @e)
    rm = bn.mont_from(mn, @r)
    u1m = bn.mont_mul(mn, @em, @w)
    u2m = bn.mont_mul(mn, @rm, @w)
    u1 = bn.mont_to(mn, @u1m)
    u2 = bn.mont_to(mn, @u2m)
    g = point_base(mc, gx, gy)
    p1 = scalar_mul(mc, @u1, @g)
    p2 = scalar_mul(mc, @u2, pub)
    sp = point_add(mc, @p1, @p2)
    if point_is_infinity(@sp) {
        return False
    }
    a = point_to_affine(mc, @sp)
    xr = a.x
    if bn.big_cmp(@xr, n) >= 0 {
        xr = bn.big_sub_mod(@xr, n, n)
    }
    return bn.big_cmp(@xr, @r) == 0
}

public def ecdsa_verify(ctx: @P256Ctx, pub: @P256Point, hash: @Bytes, sig: @Bytes) -> bool {
    mc = ctx.mc
    n = ctx.n
    mn = ctx.mn
    gx = ctx.gx
    gy = ctx.gy
    return ecdsa_verify_raw(mc, @n, @mn, @gx, @gy, pub, hash, sig)
}

# Convenience wrapper: uncompressed/compressed public key bytes in, DER signature verification.
public def ecdsa_verify_hash(public_key: @Bytes, hash: @Bytes, sig: @Bytes) -> bool {
    return ecdsa_verify_hash_ctx(ctx_new(), public_key, hash, sig)
}

public def ecdsa_verify_hash_ctx(ctx: @P256Ctx, public_key: @Bytes, hash: @Bytes, sig: @Bytes) -> bool {
    mc = ctx.mc
    b = ctx.b
    n = ctx.n
    mn = ctx.mn
    gx = ctx.gx
    gy = ctx.gy
    e = ctx.sqrt_exp
    pr = parse_raw(mc, @b, @e, public_key)
    if not pr.ok {
        return False
    }
    pub = pr.point
    return ecdsa_verify_raw(mc, @n, @mn, @gx, @gy, @pub, hash, sig)
}

public def ecdsa_sign(ctx: @P256Ctx, private_key: @Bytes, hash: @Bytes) -> Bytes {
    mc = ctx.mc
    n = ctx.n
    sb = ctx.sb
    if private_key.len != sb {
        return bytes.bytes_new(0)
    }
    mn = ctx.mn
    gx = ctx.gx
    gy = ctx.gy
    d = bn.big_from_bytes_be(private_key, mc.n)
    if not valid_private(@n, @d) {
        return bytes.bytes_new(0)
    }
    g = point_base(mc, @gx, @gy)
    e = hash_to_scalar(@n, hash)
    half = bn.big_shr(@n, 1)
    attempt = 0
    while attempt < 32 {
        kb = entropy.bytes_random(sb)
        k = bn.big_from_bytes_be(@kb, mc.n)
        if bn.big_cmp(@k, @n) >= 0 {
            k = bn.big_sub_mod(@k, @n, @n)
        }
        if bn.big_is_zero(@k) {
            attempt = attempt + 1
        } else {
            rp = scalar_mul(mc, @k, @g)
            a = point_to_affine(mc, @rp)
            r = a.x
            if bn.big_cmp(@r, @n) >= 0 {
                r = bn.big_sub_mod(@r, @n, @n)
            }
            if bn.big_is_zero(@r) {
                attempt = attempt + 1
            } else {
                km = bn.mont_from(@mn, @k)
                kinv = bn.mont_inv(@mn, @km)
                em = bn.mont_from(@mn, @e)
                rm = bn.mont_from(@mn, @r)
                dm = bn.mont_from(@mn, @d)
                rd = bn.mont_mul(@mn, @rm, @dm)
                sum = bn.mont_add(@mn, @em, @rd)
                sm = bn.mont_mul(@mn, @kinv, @sum)
                s = bn.mont_to(@mn, @sm)
                if bn.big_is_zero(@s) {
                    attempt = attempt + 1
                } else {
                    if bn.big_cmp(@s, @half) > 0 {
                        s = bn.big_sub_mod(@n, @s, @n)
                    }
                    return der_encode_sig_w(@r, @s, sb)
                }
            }
        }
    }
    return bytes.bytes_new(0)
}

public def ecdsa_sign_hash(private_key: @Bytes, hash: @Bytes) -> Bytes {
    ctx = ctx_new()
    return ecdsa_sign(ctx, private_key, hash)
}
