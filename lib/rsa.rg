# RGC standard library: rsa
#
# RSA signature verification and signing (PKCS#1 v1.5 and PSS) plus DER key
# parsing. Used by TLS 1.3 certificate-chain checks and client-certificate
# signing. Big-integer arithmetic comes from lib/bigint.rg (Montgomery);
# signing uses CRT (p, q, dp, dq, qinv) so 2048-bit keys stay fast.
#
# Usage:
#   import rsa
#   pr = rsa.parse_public(@spki_der)
#   ok = rsa.pss_verify(@pr.key, "sha256", @digest, @sig, 32)
#   sig = rsa.pss_sign(@kr.key, "sha256", @digest, 32)
#
# Notes:
#   - The verify/sign helpers take the message digest, not the message.
#   - PKCS#1 v1.5 verification is strict: exact DigestInfo, PS >= 8 bytes.
#   - PSS uses MGF1 with the same hash; salt_len = -1 auto-detects the salt
#     when verifying and defaults to the hash length when signing.
#   - Signature comparisons are not constant-time; only public data is handled.

import bytes
import bin
import bigint as bn
import sha2
import entropy
import asn1

public class RsaPublic {
    n: Big
    e: Big
    bits: int
}

public class RsaPublicResult {
    ok: bool
    error: str
    key: RsaPublic
}

public class RsaPrivate {
    n: Big
    e: Big
    d: Big
    p: Big
    q: Big
    dp: Big
    dq: Big
    qinv: Big
    bits: int
}

public class RsaPrivateResult {
    ok: bool
    error: str
    key: RsaPrivate
}

def zero_big() -> Big {
    return bn.big_new(1)
}

def pub_err(msg: str) -> RsaPublicResult {
    r = RsaPublicResult()
    r.ok = False
    r.error = msg
    k = RsaPublic()
    k.n = zero_big()
    k.e = zero_big()
    k.bits = 0
    r.key = k
    return r
}

def priv_err(msg: str) -> RsaPrivateResult {
    r = RsaPrivateResult()
    r.ok = False
    r.error = msg
    k = RsaPrivate()
    k.n = zero_big()
    k.e = zero_big()
    k.d = zero_big()
    k.p = zero_big()
    k.q = zero_big()
    k.dp = zero_big()
    k.dq = zero_big()
    k.qinv = zero_big()
    k.bits = 0
    r.key = k
    return r
}

# ---------------------------------------------------------------------------
# Hashes and encoding helpers
# ---------------------------------------------------------------------------

public def hash_len(alg: str) -> int {
    if alg == "sha256" {
        return 32
    }
    if alg == "sha384" {
        return 48
    }
    if alg == "sha512" {
        return 64
    }
    return 0
}

public def hash_bytes(alg: str, data: @Bytes) -> Bytes {
    if alg == "sha256" {
        return sha2.sha256(data)
    }
    if alg == "sha384" {
        return sha2.sha384(data)
    }
    if alg == "sha512" {
        return sha2.sha512(data)
    }
    return bytes.bytes_new(0)
}

def digest_info_prefix(alg: str) -> str {
    if alg == "sha256" {
        return "3031300d060960864801650304020105000420"
    }
    if alg == "sha384" {
        return "3041300d060960864801650304020205000430"
    }
    if alg == "sha512" {
        return "3051300d060960864801650304020305000440"
    }
    return ""
}

def digest_info(alg: str, digest: @Bytes) -> Bytes {
    pre = bin.from_hex(digest_info_prefix(alg))
    out = bytes.bytes_new(pre.len + digest.len)
    out.append(@pre)
    out.append(digest)
    return out
}

def bytes_eq(a: @Bytes, b: @Bytes) -> bool {
    if a.len != b.len {
        return False
    }
    i = 0
    while i < a.len {
        if a.get(i) != b.get(i) {
            return False
        }
        i = i + 1
    }
    return True
}

def mgf1(alg: str, seed: @Bytes, length: int) -> Bytes {
    out = bytes.bytes_new(length)
    hlen = hash_len(alg)
    counter = 0
    while out.len < length {
        ctr = bytes.bytes_new(4)
        ctr.push((counter >> 24) & 255)
        ctr.push((counter >> 16) & 255)
        ctr.push((counter >> 8) & 255)
        ctr.push(counter & 255)
        buf = bytes.bytes_concat(seed, @ctr)
        h = hash_bytes(alg, @buf)
        take = hlen
        if length - out.len < take {
            take = length - out.len
        }
        piece = h.slice(0, take)
        out.append(@piece)
        counter = counter + 1
    }
    return out
}

# ---------------------------------------------------------------------------
# Key parsing (PKCS#1 RSAPublicKey, SPKI, PKCS#1 RSAPrivateKey, PKCS#8)
# ---------------------------------------------------------------------------

def limbs_for(nbytes: int) -> int {
    n = (nbytes * 8 + 15) / 16
    if n < 1 {
        n = 1
    }
    return n
}

def tlv_big(data: @Bytes, t: @Tlv, limbs: int) -> Big {
    content = asn1.der_content(data, t)
    return bn.big_from_bytes_be(@content, limbs)
}

def parse_n_e(data: @Bytes, pos: int) -> RsaPublicResult {
    r = pub_err("bad rsa public key")
    nt = asn1.der_next(data, pos)
    if not nt.ok or nt.tag != 2 {
        return r
    }
    et = asn1.der_next(data, nt.next)
    if not et.ok or et.tag != 2 {
        return r
    }
    n = tlv_big(data, @nt, limbs_for(nt.len))
    e = tlv_big(data, @et, limbs_for(et.len))
    if bn.big_is_zero(@n) or bn.big_is_zero(@e) {
        return r
    }
    k = RsaPublic()
    k.n = n
    k.e = e
    k.bits = bn.big_bit_len(@n)
    r.ok = True
    r.error = ""
    r.key = k
    return r
}

public def parse_public(der: @Bytes) -> RsaPublicResult {
    r = pub_err("bad rsa public key")
    t = asn1.der_next(der, 0)
    if not t.ok or t.tag != 48 {
        return r
    }
    c = asn1.der_next(der, t.start)
    if not c.ok {
        return r
    }
    if c.tag == 2 {
        return parse_n_e(der, t.start)
    }
    if c.tag != 48 {
        return r
    }
    oid = asn1.der_next(der, c.start)
    if not oid.ok or oid.tag != 6 {
        return r
    }
    if not asn1.der_oid_is(der, @oid, "1.2.840.113549.1.1.1") {
        return pub_err("not an rsa key")
    }
    bs = asn1.der_next(der, c.next)
    if not bs.ok or bs.tag != 3 or bs.len < 2 {
        return r
    }
    if der.get(bs.start) != 0 {
        return r
    }
    inner = asn1.der_next(der, bs.start + 1)
    if not inner.ok or inner.tag != 48 {
        return r
    }
    return parse_n_e(der, inner.start)
}

def parse_pkcs1_private(der: @Bytes) -> RsaPrivateResult {
    r = priv_err("bad rsa private key")
    t = asn1.der_next(der, 0)
    if not t.ok or t.tag != 48 {
        return r
    }
    ver = asn1.der_next(der, t.start)
    if not ver.ok or ver.tag != 2 {
        return r
    }
    nt = asn1.der_next(der, ver.next)
    if not nt.ok or nt.tag != 2 {
        return r
    }
    et = asn1.der_next(der, nt.next)
    if not et.ok or et.tag != 2 {
        return r
    }
    dt = asn1.der_next(der, et.next)
    if not dt.ok or dt.tag != 2 {
        return r
    }
    pt = asn1.der_next(der, dt.next)
    if not pt.ok or pt.tag != 2 {
        return r
    }
    qt = asn1.der_next(der, pt.next)
    if not qt.ok or qt.tag != 2 {
        return r
    }
    dpt = asn1.der_next(der, qt.next)
    if not dpt.ok or dpt.tag != 2 {
        return r
    }
    dqt = asn1.der_next(der, dpt.next)
    if not dqt.ok or dqt.tag != 2 {
        return r
    }
    qit = asn1.der_next(der, dqt.next)
    if not qit.ok or qit.tag != 2 {
        return r
    }

    nl = limbs_for(nt.len)
    dl = limbs_for(dt.len)
    pl = limbs_for(pt.len)
    ql = limbs_for(qt.len)
    if ql > pl {
        pl = ql
    }

    k = RsaPrivate()
    kqinv = tlv_big(der, @qit, pl)
    kne = tlv_big(der, @nt, nl)
    k.n = kne
    k.e = tlv_big(der, @et, limbs_for(et.len))
    k.d = tlv_big(der, @dt, dl)
    k.p = tlv_big(der, @pt, pl)
    k.q = tlv_big(der, @qt, pl)
    k.dp = tlv_big(der, @dpt, pl)
    k.dq = tlv_big(der, @dqt, pl)
    k.qinv = kqinv
    k.bits = bn.big_bit_len(@kne)

    # n == p*q catches misaligned or truncated key files before they are used.
    kn = k.n
    kp = k.p
    kq = k.q
    if bn.big_is_zero(@kn) or bn.big_is_zero(@kp) or bn.big_is_zero(@kq) {
        return priv_err("bad rsa private key")
    }
    prod = bn.big_mul(@kp, @kq)
    if bn.big_cmp(@prod, @kn) != 0 {
        return priv_err("rsa private key mismatch")
    }

    r.ok = True
    r.error = ""
    r.key = k
    return r
}

public def parse_private(der: @Bytes) -> RsaPrivateResult {
    r = priv_err("bad rsa private key")
    t = asn1.der_next(der, 0)
    if not t.ok or t.tag != 48 {
        return r
    }
    ver = asn1.der_next(der, t.start)
    if not ver.ok or ver.tag != 2 {
        return r
    }
    c = asn1.der_next(der, ver.next)
    if not c.ok {
        return r
    }
    if c.tag == 48 {
        # PKCS#8 PrivateKeyInfo: version, AlgorithmIdentifier, OCTET STRING.
        oid = asn1.der_next(der, c.start)
        if not oid.ok or oid.tag != 6 {
            return r
        }
        if not asn1.der_oid_is(der, @oid, "1.2.840.113549.1.1.1") {
            return priv_err("not an rsa key")
        }
        oct = asn1.der_next(der, c.next)
        if not oct.ok or oct.tag != 4 {
            return r
        }
        inner = asn1.der_content(der, @oct)
        return parse_pkcs1_private(@inner)
    }
    if c.tag == 2 {
        return parse_pkcs1_private(der)
    }
    return r
}

# ---------------------------------------------------------------------------
# RSA primitives
# ---------------------------------------------------------------------------

def mod_pow_pub(pub: @RsaPublic, base: @Big) -> Big {
    n = pub.n
    e = pub.e
    mc = bn.mont_new(@n)
    bm = bn.mont_from(@mc, base)
    rm = bn.mont_pow(@mc, @bm, @e)
    return bn.mont_to(@mc, @rm)
}

def mod_pow_ctx(m: @Big, base: @Big, exp: @Big) -> Big {
    mc = bn.mont_new(m)
    bm = bn.mont_from(@mc, base)
    rm = bn.mont_pow(@mc, @bm, @exp)
    return bn.mont_to(@mc, @rm)
}

# m2 + qinv*(m1-m2) mod p, with m1 = c^dp mod p and m2 = c^dq mod q.
def crt_pow(priv: @RsaPrivate, c: @Big) -> Big {
    p = priv.p
    q = priv.q
    dp = priv.dp
    dq = priv.dq
    qi = priv.qinv
    cp = bn.big_mod(c, @p)
    cq = bn.big_mod(c, @q)
    m1 = mod_pow_ctx(@p, @cp, @dp)
    m2 = mod_pow_ctx(@q, @cq, @dq)
    diff = bn.big_sub_mod(@m1, @m2, @p)
    mc = bn.mont_new(@p)
    qm = bn.mont_from(@mc, @qi)
    dm = bn.mont_from(@mc, @diff)
    hm = bn.mont_mul(@mc, @qm, @dm)
    h = bn.mont_to(@mc, @hm)
    hq = bn.big_mul(@h, @q)
    return bn.big_add(@hq, @m2)
}

def pkcs1v15_em(k: int, alg: str, digest: @Bytes) -> Bytes {
    t = digest_info(alg, digest)
    ps = k - t.len - 3
    em = bytes.bytes_new(k)
    em.push(0)
    em.push(1)
    i = 0
    while i < ps {
        em.push(255)
        i = i + 1
    }
    em.push(0)
    em.append(@t)
    return em
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

public def pkcs1v15_verify(pub: @RsaPublic, alg: str, digest: @Bytes, sig: @Bytes) -> bool {
    hlen = hash_len(alg)
    if hlen == 0 or digest.len != hlen {
        return False
    }
    k = (pub.bits + 7) / 8
    if k < 1 or sig.len != k {
        return False
    }
    n = pub.n
    s = bn.big_from_bytes_be(sig, n.n)
    if bn.big_cmp(@s, @n) >= 0 {
        return False
    }
    m = mod_pow_pub(pub, @s)
    em = bn.big_to_bytes_be(@m, k)
    t = digest_info(alg, digest)
    if k < t.len + 11 {
        return False
    }
    if em.get(0) != 0 or em.get(1) != 1 {
        return False
    }
    ps = k - t.len - 3
    i = 2
    while i < 2 + ps {
        if em.get(i) != 255 {
            return False
        }
        i = i + 1
    }
    if em.get(2 + ps) != 0 {
        return False
    }
    i = 0
    while i < t.len {
        if em.get(3 + ps + i) != t.get(i) {
            return False
        }
        i = i + 1
    }
    return True
}

public def pss_verify(pub: @RsaPublic, alg: str, digest: @Bytes, sig: @Bytes, salt_len: int) -> bool {
    hlen = hash_len(alg)
    if hlen == 0 or digest.len != hlen {
        return False
    }
    bits = pub.bits
    k = (bits + 7) / 8
    if k < 1 or sig.len != k {
        return False
    }
    embits = bits - 1
    emlen = (embits + 7) / 8
    if emlen < hlen + 2 {
        return False
    }
    n = pub.n
    s = bn.big_from_bytes_be(sig, n.n)
    if bn.big_cmp(@s, @n) >= 0 {
        return False
    }
    m = mod_pow_pub(pub, @s)
    em = bn.big_to_bytes_be(@m, emlen)
    if em.get(emlen - 1) != 188 {
        return False
    }
    dblen = emlen - hlen - 1
    db = em.slice(0, dblen)
    h = em.slice(dblen, dblen + hlen)
    unused = 8 * emlen - embits
    topmask = 255 >> unused
    if db.get(0) & (255 - topmask) != 0 {
        return False
    }
    mask = mgf1(alg, @h, dblen)
    i = 0
    while i < dblen {
        db.set(i, db.get(i) ^ mask.get(i))
        i = i + 1
    }
    db.set(0, db.get(0) & topmask)
    pslen = dblen - salt_len - 1
    slen = salt_len
    if slen >= 0 {
        if pslen < 0 {
            return False
        }
    } else {
        i = 0
        while i < dblen and db.get(i) == 0 {
            i = i + 1
        }
        if i >= dblen {
            return False
        }
        if db.get(i) != 1 {
            return False
        }
        pslen = i
        slen = dblen - pslen - 1
    }
    i = 0
    while i < pslen {
        if db.get(i) != 0 {
            return False
        }
        i = i + 1
    }
    if db.get(pslen) != 1 {
        return False
    }
    salt = db.slice(pslen + 1, dblen)
    if salt.len != slen {
        return False
    }
    msg = bytes.bytes_new(8 + hlen + slen)
    i = 0
    while i < 8 {
        msg.push(0)
        i = i + 1
    }
    msg.append(digest)
    msg.append(@salt)
    hp = hash_bytes(alg, @msg)
    return bytes_eq(@hp, @h)
}

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------

public def pkcs1v15_sign(priv: @RsaPrivate, alg: str, digest: @Bytes) -> Bytes {
    hlen = hash_len(alg)
    if hlen == 0 or digest.len != hlen {
        return bytes.bytes_new(0)
    }
    k = (priv.bits + 7) / 8
    t = digest_info(alg, digest)
    if k < t.len + 11 {
        return bytes.bytes_new(0)
    }
    em = pkcs1v15_em(k, alg, digest)
    n = priv.n
    m = bn.big_from_bytes_be(@em, n.n)
    if bn.big_cmp(@m, @n) >= 0 {
        return bytes.bytes_new(0)
    }
    s = crt_pow(priv, @m)
    return bn.big_to_bytes_be(@s, k)
}

public def pss_sign(priv: @RsaPrivate, alg: str, digest: @Bytes, salt_len: int) -> Bytes {
    hlen = hash_len(alg)
    if hlen == 0 or digest.len != hlen {
        return bytes.bytes_new(0)
    }
    bits = priv.bits
    k = (bits + 7) / 8
    embits = bits - 1
    emlen = (embits + 7) / 8
    slen = salt_len
    if slen < 0 {
        slen = hlen
    }
    if emlen < hlen + slen + 2 {
        return bytes.bytes_new(0)
    }
    salt = entropy.bytes_random(slen)
    if salt.len != slen {
        return bytes.bytes_new(0)
    }
    msg = bytes.bytes_new(8 + hlen + slen)
    i = 0
    while i < 8 {
        msg.push(0)
        i = i + 1
    }
    msg.append(digest)
    msg.append(@salt)
    h = hash_bytes(alg, @msg)
    dblen = emlen - hlen - 1
    pslen = dblen - slen - 1
    db = bytes.bytes_new(dblen)
    i = 0
    while i < pslen {
        db.push(0)
        i = i + 1
    }
    db.push(1)
    db.append(@salt)
    mask = mgf1(alg, @h, dblen)
    i = 0
    while i < dblen {
        db.set(i, db.get(i) ^ mask.get(i))
        i = i + 1
    }
    unused = 8 * emlen - embits
    db.set(0, db.get(0) & (255 >> unused))
    em = bytes.bytes_new(emlen)
    em.append(@db)
    em.append(@h)
    em.push(188)
    n = priv.n
    m = bn.big_from_bytes_be(@em, n.n)
    s = crt_pow(priv, @m)
    return bn.big_to_bytes_be(@s, k)
}
