# RGC standard library: pkey
#
# Unified public/private key handling for TLS: SPKI parsing, PEM private-key
# parsing (PKCS#8, PKCS#1, SEC1) and signature verify/sign across RSA and
# P-256 ECDSA. Signature schemes use the TLS 1.3 SignatureScheme names.
#
# Usage:
#   import pkey
#   pr = pkey.parse_spki(@spki_der)
#   ok = pkey.verify(@pr.key, "rsa_pss_sha256", @digest, @sig)
#   sr = pkey.parse_private_pem(@pem_der)
#   sig = pkey.sign(@sr.key, "ecdsa_sha256", @digest)
#
# Notes:
#   - Supported signature schemes: rsa_pss_rsae_sha256/384/512,
#     rsa_pkcs1_sha256/384/512, ecdsa_secp256r1_sha256, and the sha384/512
#     ECDSA variants (digest truncated to 256 bits).
#   - Only RSA and secp256r1 keys are supported; other kinds parse with
#     kind="" so callers fail closed.

import bytes
import asn1
import bigint as bn
import rsa
import p256

public class PublicKey {
    kind: str
    rsa_key: RsaPublic
    ec_point: Bytes
}

public class PublicKeyResult {
    ok: bool
    error: str
    key: PublicKey
}

public class PrivateKey {
    kind: str
    rsa_key: RsaPrivate
    ec_scalar: Bytes
}

public class PrivateKeyResult {
    ok: bool
    error: str
    key: PrivateKey
}

def empty_rsa_public() -> RsaPublic {
    k = RsaPublic()
    k.n = bn.big_new(1)
    k.e = bn.big_new(1)
    k.bits = 0
    return k
}

def empty_rsa_private() -> RsaPrivate {
    k = RsaPrivate()
    k.n = bn.big_new(1)
    k.e = bn.big_new(1)
    k.d = bn.big_new(1)
    k.p = bn.big_new(1)
    k.q = bn.big_new(1)
    k.dp = bn.big_new(1)
    k.dq = bn.big_new(1)
    k.qinv = bn.big_new(1)
    k.bits = 0
    return k
}

def pub_empty(msg: str) -> PublicKeyResult {
    r = PublicKeyResult()
    r.ok = False
    r.error = msg
    k = PublicKey()
    k.kind = ""
    k.rsa_key = empty_rsa_public()
    k.ec_point = bytes.bytes_new(0)
    r.key = k
    return r
}

def priv_empty(msg: str) -> PrivateKeyResult {
    r = PrivateKeyResult()
    r.ok = False
    r.error = msg
    k = PrivateKey()
    k.kind = ""
    k.rsa_key = empty_rsa_private()
    k.ec_scalar = bytes.bytes_new(0)
    r.key = k
    return r
}

public def hash_for_scheme(scheme: str) -> str {
    if scheme == "rsa_pss_rsae_sha256" or scheme == "rsa_pkcs1_sha256" or scheme == "ecdsa_secp256r1_sha256" {
        return "sha256"
    }
    if scheme == "rsa_pss_rsae_sha384" or scheme == "rsa_pkcs1_sha384" or scheme == "ecdsa_secp384r1_sha384" {
        return "sha384"
    }
    if scheme == "rsa_pss_rsae_sha512" or scheme == "rsa_pkcs1_sha512" or scheme == "ecdsa_secp521r1_sha512" {
        return "sha512"
    }
    return ""
}

# ---------------------------------------------------------------------------
# Public keys (SubjectPublicKeyInfo)
# ---------------------------------------------------------------------------

public def parse_spki(der: @Bytes) -> PublicKeyResult {
    r = pub_empty("bad spki")
    t = asn1.der_next(der, 0)
    if not t.ok or t.tag != 48 {
        return r
    }
    alg = asn1.der_next(der, t.start)
    if not alg.ok or alg.tag != 48 {
        return r
    }
    oid = asn1.der_next(der, alg.start)
    if not oid.ok or oid.tag != 6 {
        return r
    }
    bs = asn1.der_next(der, alg.next)
    if not bs.ok or bs.tag != 3 or bs.len < 2 {
        return r
    }
    if der.get(bs.start) != 0 {
        return r
    }

    if asn1.der_oid_is(der, @oid, "1.2.840.113549.1.1.1") {
        pr = rsa.parse_public(der)
        if not pr.ok {
            return pub_empty(pr.error)
        }
        k = PublicKey()
        k.kind = "rsa"
        k.rsa_key = pr.key
        k.ec_point = bytes.bytes_new(0)
        r.ok = True
        r.error = ""
        r.key = k
        return r
    }
    if asn1.der_oid_is(der, @oid, "1.2.840.10045.2.1") {
        curve = asn1.der_next(der, oid.next)
        if not curve.ok or curve.tag != 6 {
            return r
        }
        curve_ok = asn1.der_oid_is(der, @curve, "1.2.840.10045.3.1.7")
        curve_ok_p384 = asn1.der_oid_is(der, @curve, "1.3.132.0.34")
        if not curve_ok and not curve_ok_p384 {
            return pub_empty("unsupported ec curve")
        }
        point = der.slice(bs.start + 1, bs.start + bs.len)
        cp = p256.parse_public(@point)
        if curve_ok_p384 {
            c384 = p256.ctx_new_p384()
            cp = p256.parse_public_ctx(c384, @point)
        }
        if not cp.ok {
            return pub_empty("bad ec point")
        }
        k = PublicKey()
        k.kind = "ec256"
        if curve_ok_p384 {
            k.kind = "ec384"
        }
        k.rsa_key = empty_rsa_public()
        k.ec_point = point
        r.ok = True
        r.error = ""
        r.key = k
        return r
    }
    return pub_empty("unsupported key algorithm")
}

# ---------------------------------------------------------------------------
# Private keys (PKCS#8, PKCS#1 RSAPrivateKey, SEC1 ECPrivateKey)
# ---------------------------------------------------------------------------

def pad_scalar(content: @Bytes) -> Bytes {
    out = bytes.bytes_new(32)
    i = 0
    while i < 32 {
        out.push(0)
        i = i + 1
    }
    n = content.len
    if n > 32 {
        n = 32
    }
    i = 0
    while i < n {
        out.set(32 - n + i, content.get(content.len - n + i))
        i = i + 1
    }
    return out
}

def parse_sec1(der: @Bytes) -> PrivateKeyResult {
    r = priv_empty("bad ec private key")
    t = asn1.der_next(der, 0)
    if not t.ok or t.tag != 48 {
        return r
    }
    ver = asn1.der_next(der, t.start)
    if not ver.ok or ver.tag != 2 {
        return r
    }
    oct = asn1.der_next(der, ver.next)
    if not oct.ok or oct.tag != 4 {
        return r
    }
    content = asn1.der_content(der, @oct)
    if content.len < 1 or content.len > 32 {
        return r
    }
    scalar = pad_scalar(@content)
    # A zero scalar cannot be used; reject it early.
    sb = bn.big_from_bytes_be(@scalar, 16)
    if bn.big_is_zero(@sb) {
        return r
    }
    k = PrivateKey()
    k.kind = "ec256"
    k.rsa_key = empty_rsa_private()
    k.ec_scalar = scalar
    r.ok = True
    r.error = ""
    r.key = k
    return r
}

public def parse_private(der: @Bytes) -> PrivateKeyResult {
    r = priv_empty("bad private key")
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
        # PKCS#8 PrivateKeyInfo.
        oid = asn1.der_next(der, c.start)
        if not oid.ok or oid.tag != 6 {
            return r
        }
        oct = asn1.der_next(der, c.next)
        if not oct.ok or oct.tag != 4 {
            return r
        }
        if asn1.der_oid_is(der, @oid, "1.2.840.113549.1.1.1") {
            pr = rsa.parse_private(der)
            if not pr.ok {
                return priv_empty(pr.error)
            }
            k = PrivateKey()
            k.kind = "rsa"
            k.rsa_key = pr.key
            k.ec_scalar = bytes.bytes_new(0)
            r.ok = True
            r.error = ""
            r.key = k
            return r
        }
        if asn1.der_oid_is(der, @oid, "1.2.840.10045.2.1") {
            inner = asn1.der_content(der, @oct)
            return parse_sec1(@inner)
        }
        return priv_empty("unsupported key algorithm")
    }
    if c.tag == 2 {
        pr = rsa.parse_private(der)
        if not pr.ok {
            return priv_empty(pr.error)
        }
        k = PrivateKey()
        k.kind = "rsa"
        k.rsa_key = pr.key
        k.ec_scalar = bytes.bytes_new(0)
        r.ok = True
        r.error = ""
        r.key = k
        return r
    }
    if c.tag == 4 {
        return parse_sec1(der)
    }
    return r
}

# ---------------------------------------------------------------------------
# Signatures
# ---------------------------------------------------------------------------

public def verify(k: @PublicKey, scheme: str, digest: @Bytes, sig: @Bytes) -> bool {
    alg = hash_for_scheme(scheme)
    if alg.len() == 0 {
        return False
    }
    if k.kind == "rsa" {
        rk = k.rsa_key
        if scheme == "rsa_pss_rsae_sha256" or scheme == "rsa_pss_rsae_sha384" or scheme == "rsa_pss_rsae_sha512" {
            return rsa.pss_verify(@rk, alg, digest, sig, -1)
        }
        return rsa.pkcs1v15_verify(@rk, alg, digest, sig)
    }
    if k.kind == "ec256" {
        ec = k.ec_point
        return p256.ecdsa_verify_hash(@ec, digest, sig)
    }
    if k.kind == "ec384" {
        ec = k.ec_point
        c384 = p256.ctx_new_p384()
        return p256.ecdsa_verify_hash_ctx(c384, @ec, digest, sig)
    }
    return False
}

public def sign(k: @PrivateKey, scheme: str, digest: @Bytes) -> Bytes {
    alg = hash_for_scheme(scheme)
    if alg.len() == 0 {
        return bytes.bytes_new(0)
    }
    if k.kind == "rsa" {
        rk = k.rsa_key
        if scheme == "rsa_pss_rsae_sha256" or scheme == "rsa_pss_rsae_sha384" or scheme == "rsa_pss_rsae_sha512" {
            return rsa.pss_sign(@rk, alg, digest, rsa.hash_len(alg))
        }
        return rsa.pkcs1v15_sign(@rk, alg, digest)
    }
    if k.kind == "ec256" {
        sc = k.ec_scalar
        return p256.ecdsa_sign_hash(@sc, digest)
    }
    return bytes.bytes_new(0)
}

public def scheme_fits_key(k: @PublicKey, scheme: str) -> bool {
    if k.kind == "rsa" {
        return scheme == "rsa_pss_rsae_sha256" or scheme == "rsa_pss_rsae_sha384" or
               scheme == "rsa_pss_rsae_sha512" or scheme == "rsa_pkcs1_sha256" or
               scheme == "rsa_pkcs1_sha384" or scheme == "rsa_pkcs1_sha512"
    }
    if k.kind == "ec256" {
        return scheme == "ecdsa_secp256r1_sha256"
    }
    if k.kind == "ec384" {
        return scheme == "ecdsa_secp384r1_sha384"
    }
    return False
}
