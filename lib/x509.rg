# RGC standard library: x509
#
# X.509 certificate parsing and path validation for the pure-RGC TLS 1.3
# client: tbs/signature extraction, validity, issuer/subject names, SPKI,
# SAN dNSName/iPAddress, basicConstraints, keyUsage, extendedKeyUsage, CN,
# PEM CA bundles and hostname/IP matching.
#
# Usage:
#   import x509
#   cr = x509.parse(@cert_der)
#   store = x509.store_load_system()
#   vr = x509.verify_chain(@cr.cert, @intermediates, @store, "example.com", time.now())
#
# Notes:
#   - Chain building tries peer intermediates first, then trust anchors whose
#     subject matches the issuer; signatures are verified at every step.
#   - Validity, CA/basicConstraints, pathLen and keyCertSign are enforced.
#   - Unknown critical extensions make a certificate unusable (fail closed).
#   - Only RSA and secp256r1 issuer keys are supported, matching lib/pkey.rg.
#   - CA bundles come from SSL_CERT_FILE or the usual system bundle paths;
#     directory-style stores (SSL_CERT_DIR) are not scanned.

import bytes
import asn1
import bigint as bn
import sha2
import rsa
import p256
import pkey

public class X509Cert {
    ok: bool
    error: str
    der: Bytes
    tbs: Bytes
    sig_alg: str
    sig_params: Bytes
    sig: Bytes
    issuer: Bytes
    subject: Bytes
    serial: Bytes
    not_before: int
    not_after: int
    spki: Bytes
    pub: PublicKey
    san_dns: List[str]
    san_ips: List[Bytes]
    cn: str
    is_ca: bool
    path_len: int
    has_key_usage: bool
    key_usage: int
    eku_server: bool
    eku_client: bool
    has_eku: bool
    unsupported_critical: bool
    used: bool
}

public class X509Store {
    certs: List[X509Cert]
}

public class X509VerifyResult {
    ok: bool
    error: str
}

def empty_pub() -> PublicKey {
    none = bytes.bytes_new(0)
    pr = rsa.parse_public(@none)
    k = PublicKey()
    k.kind = ""
    k.rsa_key = pr.key
    k.ec_point = bytes.bytes_new(0)
    return k
}

def cert_error(msg: str) -> X509Cert {
    c = X509Cert()
    c.ok = False
    c.error = msg
    c.der = bytes.bytes_new(0)
    c.tbs = bytes.bytes_new(0)
    c.sig_alg = ""
    c.sig_params = bytes.bytes_new(0)
    c.sig = bytes.bytes_new(0)
    c.issuer = bytes.bytes_new(0)
    c.subject = bytes.bytes_new(0)
    c.serial = bytes.bytes_new(0)
    c.not_before = 0
    c.not_after = 0
    c.spki = bytes.bytes_new(0)
    c.pub = empty_pub()
    c.san_dns = List[str]()
    c.san_ips = List[Bytes]()
    c.cn = ""
    c.is_ca = False
    c.path_len = -1
    c.has_key_usage = False
    c.key_usage = 0
    c.eku_server = False
    c.eku_client = False
    c.has_eku = False
    c.unsupported_critical = False
    c.used = False
    return c
}

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def num_at(s: str, pos: int, count: int) -> int {
    v = 0
    i = 0
    while i < count {
        c = s.char_at(pos + i)
        if c < 48 or c > 57 {
            return -1
        }
        v = v * 10 + (c - 48)
        i = i + 1
    }
    return v
}

def days_from_civil(y: int, m: int, d: int) -> int {
    yy = y
    if m <= 2 {
        yy = yy - 1
    }
    era = yy / 400
    yoe = yy - era * 400
    mp = m + 9
    if m > 2 {
        mp = m - 3
    }
    doy = (153 * mp + 2) / 5 + d - 1
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

def parse_time(data: @Bytes, t: @Tlv) -> int {
    raw = data.slice(t.start, t.start + t.len)
    s = raw.to_str()
    y = 0
    mo = 0
    d = 0
    hh = 0
    mi = 0
    ss = 0
    if t.tag == 23 {
        if s.len() < 12 {
            return -1
        }
        yy = num_at(s, 0, 2)
        mo = num_at(s, 2, 2)
        d = num_at(s, 4, 2)
        hh = num_at(s, 6, 2)
        mi = num_at(s, 8, 2)
        ss = num_at(s, 10, 2)
        if yy < 0 {
            return -1
        }
        if yy >= 50 {
            y = 1900 + yy
        } else {
            y = 2000 + yy
        }
    } elif t.tag == 24 {
        if s.len() < 14 {
            return -1
        }
        y = num_at(s, 0, 4)
        mo = num_at(s, 4, 2)
        d = num_at(s, 6, 2)
        hh = num_at(s, 8, 2)
        mi = num_at(s, 10, 2)
        ss = num_at(s, 12, 2)
    } else {
        return -1
    }
    if y < 0 or mo < 1 or mo > 12 or d < 1 or d > 31 or hh < 0 or mi < 0 or ss < 0 {
        return -1
    }
    return days_from_civil(y, mo, d) * 86400 + hh * 3600 + mi * 60 + ss
}

# ---------------------------------------------------------------------------
# Name / extension helpers
# ---------------------------------------------------------------------------

def name_cn(name: @Bytes) -> str {
    t = asn1.der_next(name, 0)
    if not t.ok or t.tag != 48 {
        return ""
    }
    p = t.start
    while p < t.start + t.len {
        rdn = asn1.der_next(name, p)
        if not rdn.ok {
            return ""
        }
        q = rdn.start
        while q < rdn.start + rdn.len {
            atv = asn1.der_next(name, q)
            if not atv.ok {
                return ""
            }
            oid = asn1.der_next(name, atv.start)
            if not oid.ok or oid.tag != 6 {
                return ""
            }
            val = asn1.der_next(name, oid.next)
            if not val.ok {
                return ""
            }
            if asn1.der_oid_is(name, @oid, "2.5.4.3") {
                if val.tag == 12 or val.tag == 19 or val.tag == 20 or val.tag == 22 {
                    raw = name.slice(val.start, val.start + val.len)
                    return raw.to_str()
                }
            }
            q = atv.next
        }
        p = rdn.next
    }
    return ""
}

def small_int(data: @Bytes, t: @Tlv) -> int {
    v = 0
    i = t.start
    while i < t.start + t.len {
        v = v * 256 + data.get(i)
        i = i + 1
    }
    return v
}

def parse_san(cert: @var X509Cert, val: @Bytes) {
    s = asn1.der_next(val, 0)
    if not s.ok or s.tag != 48 {
        return
    }
    p = s.start
    while p < s.start + s.len {
        g = asn1.der_next(val, p)
        if not g.ok {
            return
        }
        if g.tag == 130 {
            raw = val.slice(g.start, g.start + g.len)
            cert.san_dns.push(raw.to_str())
        } elif g.tag == 135 {
            raw = val.slice(g.start, g.start + g.len)
            cert.san_ips.push(raw)
        }
        p = g.next
    }
}

def parse_basic_constraints(cert: @var X509Cert, val: @Bytes) {
    s = asn1.der_next(val, 0)
    if not s.ok or s.tag != 48 {
        return
    }
    p = s.start
    while p < s.start + s.len {
        c = asn1.der_next(val, p)
        if not c.ok {
            return
        }
        if c.tag == 1 {
            cert.is_ca = val.get(c.start) != 0
        } elif c.tag == 2 {
            cert.path_len = small_int(val, @c)
        }
        p = c.next
    }
}

def parse_key_usage(cert: @var X509Cert, val: @Bytes) {
    b = asn1.der_next(val, 0)
    if not b.ok or b.tag != 3 or b.len < 2 {
        return
    }
    cert.has_key_usage = True
    cert.key_usage = val.get(b.start + 1)
}

def parse_eku(cert: @var X509Cert, val: @Bytes) {
    s = asn1.der_next(val, 0)
    if not s.ok or s.tag != 48 {
        return
    }
    cert.has_eku = True
    p = s.start
    while p < s.start + s.len {
        o = asn1.der_next(val, p)
        if not o.ok {
            return
        }
        if asn1.der_oid_is(val, @o, "1.3.6.1.5.5.7.3.1") {
            cert.eku_server = True
        }
        if asn1.der_oid_is(val, @o, "1.3.6.1.5.5.7.3.2") {
            cert.eku_client = True
        }
        p = o.next
    }
}

def parse_extensions(cert: @var X509Cert, der: @Bytes, ext: @Tlv) {
    seq = asn1.der_next(der, ext.start)
    if not seq.ok or seq.tag != 48 {
        return
    }
    p = seq.start
    while p < seq.start + seq.len {
        e = asn1.der_next(der, p)
        if not e.ok or e.tag != 48 {
            return
        }
        oid = asn1.der_next(der, e.start)
        if not oid.ok or oid.tag != 6 {
            return
        }
        q = oid.next
        critical = False
        f = asn1.der_next(der, q)
        if f.ok and f.tag == 1 {
            critical = der.get(f.start) != 0
            q = f.next
            f = asn1.der_next(der, q)
        }
        if not f.ok or f.tag != 4 {
            p = e.next
            continue
        }
        if asn1.der_oid_is(der, @oid, "2.5.29.17") {
            val = asn1.der_content(der, @f)
            parse_san(@var cert, @val)
        } elif asn1.der_oid_is(der, @oid, "2.5.29.19") {
            val = asn1.der_content(der, @f)
            parse_basic_constraints(@var cert, @val)
        } elif asn1.der_oid_is(der, @oid, "2.5.29.15") {
            val = asn1.der_content(der, @f)
            parse_key_usage(@var cert, @val)
        } elif asn1.der_oid_is(der, @oid, "2.5.29.37") {
            val = asn1.der_content(der, @f)
            parse_eku(@var cert, @val)
        } elif critical and not asn1.der_oid_is(der, @oid, "2.5.29.14") and
                not asn1.der_oid_is(der, @oid, "2.5.29.35") and
                not asn1.der_oid_is(der, @oid, "2.5.29.32") {
            # Unknown critical extension: RFC 5280 says reject the certificate.
            cert.unsupported_critical = True
        }
        p = e.next
    }
}

# ---------------------------------------------------------------------------
# Certificate parsing
# ---------------------------------------------------------------------------

public def parse(der: @Bytes) -> X509Cert {
    cert = cert_error("bad certificate")
    outer = asn1.der_next(der, 0)
    if not outer.ok or outer.tag != 48 {
        return cert
    }
    tbs_t = asn1.der_next(der, outer.start)
    if not tbs_t.ok or tbs_t.tag != 48 {
        return cert
    }
    tbs_raw = der.slice(outer.start, tbs_t.next)

    alg_t = asn1.der_next(der, tbs_t.next)
    if not alg_t.ok or alg_t.tag != 48 {
        return cert
    }
    alg_oid = asn1.der_next(der, alg_t.start)
    if not alg_oid.ok or alg_oid.tag != 6 {
        return cert
    }
    params = bytes.bytes_new(0)
    if alg_oid.next < alg_t.next {
        pt = asn1.der_next(der, alg_oid.next)
        if pt.ok {
            params = der.slice(alg_oid.next, pt.next)
        }
    }
    sig_t = asn1.der_next(der, alg_t.next)
    if not sig_t.ok or sig_t.tag != 3 or sig_t.len < 2 {
        return cert
    }
    sig_raw = der.slice(sig_t.start + 1, sig_t.start + sig_t.len)

    cert.ok = True
    cert.error = ""
    cert.der = der.slice(0, der.len)
    cert.tbs = tbs_raw
    cert.sig_alg = asn1.der_oid_str(der, @alg_oid)
    cert.sig_params = params
    cert.sig = sig_raw

    # TBSCertificate fields.
    pos = tbs_t.start
    f = asn1.der_next(der, pos)
    if f.ok and f.tag == 160 {
        pos = f.next
        f = asn1.der_next(der, pos)
    }
    if not f.ok or f.tag != 2 {
        return cert_error("bad certificate serial")
    }
    cert.serial = asn1.der_content(der, @f)
    pos = f.next
    sig2 = asn1.der_next(der, pos)
    if not sig2.ok or sig2.tag != 48 {
        return cert_error("bad certificate signature algorithm")
    }
    pos = sig2.next
    iss_start = pos
    iss = asn1.der_next(der, pos)
    if not iss.ok or iss.tag != 48 {
        return cert_error("bad certificate issuer")
    }
    cert.issuer = der.slice(iss_start, iss.next)
    pos = iss.next
    validity = asn1.der_next(der, pos)
    if not validity.ok or validity.tag != 48 {
        return cert_error("bad certificate validity")
    }
    nb = asn1.der_next(der, validity.start)
    if not nb.ok {
        return cert_error("bad notBefore")
    }
    na = asn1.der_next(der, nb.next)
    if not na.ok {
        return cert_error("bad notAfter")
    }
    cert.not_before = parse_time(der, @nb)
    cert.not_after = parse_time(der, @na)
    if cert.not_before < 0 or cert.not_after < 0 {
        return cert_error("bad certificate time")
    }
    pos = validity.next
    sub_start = pos
    sub = asn1.der_next(der, pos)
    if not sub.ok or sub.tag != 48 {
        return cert_error("bad certificate subject")
    }
    cert.subject = der.slice(sub_start, sub.next)
    subj = der.slice(sub_start, sub.next)
    cert.cn = name_cn(@subj)
    pos = sub.next
    spki_start = pos
    spki = asn1.der_next(der, pos)
    if not spki.ok or spki.tag != 48 {
        return cert_error("bad certificate spki")
    }
    cert.spki = der.slice(spki_start, spki.next)
    pos = spki.next
    # Optional issuerUniqueID [1], subjectUniqueID [2], extensions [3].
    while pos < tbs_t.next {
        opt = asn1.der_next(der, pos)
        if not opt.ok {
            break
        }
        if opt.tag == 163 {
            parse_extensions(@var cert, der, @opt)
        }
        pos = opt.next
    }

    spki_der = cert.spki
    pr = pkey.parse_spki(@spki_der)
    if not pr.ok {
        return cert_error(pr.error)
    }
    cert.pub = pr.key
    return cert
}

# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------

class PssParams {
    hash: str
    salt: int
    ok: bool
}

def pss_params(params: @Bytes) -> PssParams {
    p = PssParams()
    p.hash = ""
    p.salt = 20
    p.ok = False
    t = asn1.der_next(params, 0)
    if not t.ok or t.tag != 48 {
        return p
    }
    pos = t.start
    while pos < t.start + t.len {
        c = asn1.der_next(params, pos)
        if not c.ok {
            return p
        }
        idx = c.tag & 31
        if c.tag == 160 {
            alg = asn1.der_next(params, c.start)
            if not alg.ok or alg.tag != 48 {
                return p
            }
            oid = asn1.der_next(params, alg.start)
            if not oid.ok or oid.tag != 6 {
                return p
            }
            p.hash = hash_from_oid(params, @oid)
        } elif c.tag == 162 {
            it = asn1.der_next(params, c.start)
            if it.ok and it.tag == 2 {
                p.salt = small_int(params, @it)
            }
        }
        pos = c.next
    }
    p.ok = p.hash.len() > 0
    return p
}

def hash_from_oid(data: @Bytes, t: @Tlv) -> str {
    if asn1.der_oid_is(data, t, "2.16.840.1.101.3.4.2.1") {
        return "sha256"
    }
    if asn1.der_oid_is(data, t, "2.16.840.1.101.3.4.2.2") {
        return "sha384"
    }
    if asn1.der_oid_is(data, t, "2.16.840.1.101.3.4.2.3") {
        return "sha512"
    }
    return ""
}

def digest_for(alg: str, data: @Bytes) -> Bytes {
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

# Verify that `issuer_pub` signed `cert`. Signature algorithm comes from the
# certificate itself, including RSASSA-PSS parameters.
public def verify_signed(cert: @X509Cert, issuer_pub: @PublicKey) -> bool {
    alg_oid = cert.sig_alg
    params = cert.sig_params
    tbs = cert.tbs
    sig = cert.sig
    if issuer_pub.kind == "rsa" {
        k = issuer_pub.rsa_key
        if alg_oid == "1.2.840.113549.1.1.10" {
            pp = pss_params(@params)
            if not pp.ok {
                return False
            }
            dg = digest_for(pp.hash, @tbs)
            if dg.len == 0 {
                return False
            }
            return rsa.pss_verify(@k, pp.hash, @dg, @sig, pp.salt)
        }
        if alg_oid == "1.2.840.113549.1.1.11" {
            dg = sha2.sha256(@tbs)
            return rsa.pkcs1v15_verify(@k, "sha256", @dg, @sig)
        }
        if alg_oid == "1.2.840.113549.1.1.12" {
            dg = sha2.sha384(@tbs)
            return rsa.pkcs1v15_verify(@k, "sha384", @dg, @sig)
        }
        if alg_oid == "1.2.840.113549.1.1.13" {
            dg = sha2.sha512(@tbs)
            return rsa.pkcs1v15_verify(@k, "sha512", @dg, @sig)
        }
        return False
    }
    if issuer_pub.kind == "ec256" or issuer_pub.kind == "ec384" {
        ec = issuer_pub.ec_point
        dg = bytes.bytes_new(0)
        if alg_oid == "1.2.840.10045.4.3.2" {
            dg = sha2.sha256(@tbs)
        } elif alg_oid == "1.2.840.10045.4.3.3" {
            dg = sha2.sha384(@tbs)
        } elif alg_oid == "1.2.840.10045.4.3.4" {
            dg = sha2.sha512(@tbs)
        } else {
            return False
        }
        if issuer_pub.kind == "ec384" {
            c384 = p256.ctx_new_p384()
            return p256.ecdsa_verify_hash_ctx(c384, @ec, @dg, @sig)
        }
        return p256.ecdsa_verify_hash(@ec, @dg, @sig)
    }
    return False
}

# ---------------------------------------------------------------------------
# Stores (CA bundles)
# ---------------------------------------------------------------------------

public def store_new() -> X509Store {
    s = X509Store()
    s.certs = List[X509Cert]()
    return s
}

public def store_add_pem(st: @var X509Store, pem: @Bytes) -> int {
    added = 0
    pos = 0
    while pos < pem.len {
        b = asn1.pem_next(pem, pos)
        if not b.ok {
            break
        }
        pos = b.next
        if b.label == "CERTIFICATE" or b.label == "TRUSTED CERTIFICATE" {
            d = b.der
            c = parse(@d)
            if c.ok {
                st.certs.push(c)
                added = added + 1
            }
        }
    }
    return added
}

def store_add_file(st: @var X509Store, path: str) -> int {
    fr = bytes.read_bytes(path)
    if not fr.ok {
        return 0
    }
    data = fr.data
    return store_add_pem(@var st, @data)
}

public def store_load_system() -> X509Store {
    st = store_new()
    env = os.getenv("SSL_CERT_FILE")
    if not env.is_nothing() {
        p = env.unwrap()
        if p.len() > 0 {
            store_add_file(@var st, p)
            if st.certs.len() > 0 {
                return st
            }
        }
    }
    paths = List[str]()
    paths.push("/etc/ssl/certs/ca-certificates.crt")
    paths.push("/etc/pki/tls/certs/ca-bundle.crt")
    paths.push("/etc/ssl/ca-bundle.pem")
    paths.push("/etc/ssl/cert.pem")
    paths.push("/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
    i = 0
    while i < paths.len() {
        p = paths.get(i)
        store_add_file(@var st, p)
        if st.certs.len() > 0 {
            return st
        }
        i = i + 1
    }
    return st
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

# ---------------------------------------------------------------------------
# Chain validation
# ---------------------------------------------------------------------------

def verify_fail(msg: str) -> X509VerifyResult {
    v = X509VerifyResult()
    v.ok = False
    v.error = msg
    return v
}

def time_ok(c: @X509Cert, now: int) -> bool {
    return now >= c.not_before and now <= c.not_after
}

def issuer_constraints_ok(c: @X509Cert) -> bool {
    if not c.is_ca {
        return False
    }
    if c.unsupported_critical {
        return False
    }
    if c.has_key_usage and (c.key_usage & 4) == 0 {
        return False
    }
    return True
}

public def verify_chain(leaf: @X509Cert, chain: @List[X509Cert], store: @X509Store,
                        now: int) -> X509VerifyResult {
    if not leaf.ok {
        return verify_fail("bad leaf certificate")
    }
    if leaf.unsupported_critical {
        return verify_fail("unsupported critical extension")
    }
    if not time_ok(leaf, now) {
        return verify_fail("certificate is expired or not yet valid")
    }
    if leaf.has_eku and not leaf.eku_server {
        return verify_fail("certificate is not valid for server authentication")
    }
    if leaf.has_key_usage and (leaf.key_usage & 128) == 0 {
        return verify_fail("certificate does not allow digital signatures")
    }

    cur = leaf
    intermediates = 0
    steps = 0
    while steps < 10 {
        # A self-issued certificate that matches a trust anchor ends the path.
        if bytes_eq(cur.subject, cur.issuer) {
            cp = cur.pub
            if verify_signed(cur, @cp) {
                i = 0
                while i < store.certs.len() {
                    root = store.certs.get(i)
                    if bytes_eq(root.der, cur.der) {
                        if issuer_constraints_ok(@root) or bytes_eq(root.subject, root.issuer) {
                            v = X509VerifyResult()
                            v.ok = True
                            v.error = ""
                            return v
                        }
                    }
                    i = i + 1
                }
            }
        }

        found = -1
        i = 0
        while i < chain.len() {
            cand = chain.get(i)
            if not cand.used {
                if cand.ok and bytes_eq(cand.subject, cur.issuer) {
                    cpub = cand.pub
                    if verify_signed(cur, @cpub) {
                        found = i
                    }
                }
            }
            i = i + 1
        }
        if found >= 0 {
            nxt = chain.get(found)
            if nxt.unsupported_critical {
                return verify_fail("unsupported critical extension in chain")
            }
            if not issuer_constraints_ok(@nxt) {
                return verify_fail("chain issuer is not a ca")
            }
            if not time_ok(@nxt, now) {
                return verify_fail("certificate is expired or not yet valid")
            }
            if nxt.path_len >= 0 and intermediates > nxt.path_len {
                return verify_fail("path length constraint exceeded")
            }
            nxt.used = True
            cur = nxt
            intermediates = intermediates + 1
            steps = steps + 1
            continue
        }

        i = 0
        while i < store.certs.len() {
            root = store.certs.get(i)
            if root.ok and bytes_eq(root.subject, cur.issuer) {
                rpub = root.pub
                if verify_signed(cur, @rpub) {
                    if root.unsupported_critical {
                        return verify_fail("unsupported critical extension in trust anchor")
                    }
                    if not issuer_constraints_ok(@root) {
                        return verify_fail("trust anchor is not a ca")
                    }
                    if not time_ok(@root, now) {
                        return verify_fail("certificate is expired or not yet valid")
                    }
                    v = X509VerifyResult()
                    v.ok = True
                    v.error = ""
                    return v
                }
            }
            i = i + 1
        }
        # Cross-signed root: the wire certificate may be issued by another CA,
        # yet a trust anchor with the same subject and public key vouches for it.
        i = 0
        while i < store.certs.len() {
            root = store.certs.get(i)
            if root.ok and bytes_eq(root.subject, cur.subject) {
                cspki = cur.spki
                rspki = root.spki
                if bytes_eq(cspki, rspki) {
                    if root.unsupported_critical {
                        return verify_fail("unsupported critical extension in trust anchor")
                    }
                    if not issuer_constraints_ok(@root) {
                        return verify_fail("trust anchor is not a ca")
                    }
                    if not time_ok(@root, now) {
                        return verify_fail("certificate is expired or not yet valid")
                    }
                    v = X509VerifyResult()
                    v.ok = True
                    v.error = ""
                    return v
                }
            }
            i = i + 1
        }
        return verify_fail("unable to find issuer certificate")
    }
    return verify_fail("certificate chain too long")
}

# ---------------------------------------------------------------------------
# Hostname / IP matching
# ---------------------------------------------------------------------------

def lower_ascii(c: int) -> int {
    if c >= 65 and c <= 90 {
        return c + 32
    }
    return c
}

def str_eq_ci(a: str, b: str) -> bool {
    if a.len() != b.len() {
        return False
    }
    i = 0
    while i < a.len() {
        if lower_ascii(a.char_at(i)) != lower_ascii(b.char_at(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def ends_with_ci(s: str, suffix: str) -> bool {
    if suffix.len() > s.len() {
        return False
    }
    off = s.len() - suffix.len()
    i = 0
    while i < suffix.len() {
        if lower_ascii(s.char_at(off + i)) != lower_ascii(suffix.char_at(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def is_ip_literal(host: str) -> bool {
    if host.contains(":") {
        return True
    }
    n = host.len()
    if n == 0 {
        return False
    }
    i = 0
    while i < n {
        c = host.char_at(i)
        if c != 46 and (c < 48 or c > 57) {
            return False
        }
        i = i + 1
    }
    return True
}

def parse_ipv4(host: str) -> Bytes {
    out = bytes.bytes_new(4)
    v = 0
    parts = 0
    digits = 0
    i = 0
    while i < host.len() {
        c = host.char_at(i)
        if c == 46 {
            if digits == 0 or v > 255 or parts >= 3 {
                return bytes.bytes_new(0)
            }
            out.push(v)
            parts = parts + 1
            v = 0
            digits = 0
        } elif c >= 48 and c <= 57 {
            v = v * 10 + (c - 48)
            digits = digits + 1
            if digits > 3 {
                return bytes.bytes_new(0)
            }
        } else {
            return bytes.bytes_new(0)
        }
        i = i + 1
    }
    if digits == 0 or v > 255 or parts != 3 {
        return bytes.bytes_new(0)
    }
    out.push(v)
    return out
}

def match_one_dns(pattern: str, host: str) -> bool {
    if pattern.len() == 0 {
        return False
    }
    if pattern.char_at(0) == 42 {
        if pattern.len() < 3 or pattern.char_at(1) != 46 {
            return False
        }
        suffix = pattern.slice(2, pattern.len())
        if not ends_with_ci(host, suffix) {
            return False
        }
        head_len = host.len() - suffix.len()
        if head_len < 2 or host.char_at(head_len - 1) != 46 {
            return False
        }
        i = 0
        while i < head_len - 1 {
            if host.char_at(i) == 46 {
                return False
            }
            i = i + 1
        }
        return True
    }
    return str_eq_ci(pattern, host)
}

public def hostname_matches(cert: @X509Cert, host: str) -> bool {
    if not cert.ok {
        return False
    }
    if is_ip_literal(host) {
        if host.contains(":") {
            return False
        }
        want = parse_ipv4(host)
        if want.len != 4 {
            return False
        }
        i = 0
        while i < cert.san_ips.len() {
            ip = cert.san_ips.get(i)
            if bytes_eq(@ip, @want) {
                return True
            }
            i = i + 1
        }
        return False
    }
    i = 0
    while i < cert.san_dns.len() {
        pat = cert.san_dns.get(i)
        if match_one_dns(pat, host) {
            return True
        }
        i = i + 1
    }
    if cert.san_dns.len() > 0 or cert.san_ips.len() > 0 {
        return False
    }
    return match_one_dns(cert.cn, host)
}
