# RGC standard library: tls
#
# Pure-RGC synchronous TLS 1.3 client (RFC 8446). No OpenSSL: the handshake,
# key schedule, record layer and certificate checks are implemented in RGC on
# top of lib/sha2.rg, lib/hkdf.rg, lib/aes.rg, lib/chacha20poly1305.rg,
# lib/x25519.rg, lib/p256.rg, lib/pkey.rg and lib/x509.rg.
#
# Features:
#   - groups: x25519 and secp256r1 (both key shares are sent in the ClientHello)
#   - cipher suites: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384,
#     TLS_CHACHA20_POLY1305_SHA256
#   - certificate chains verified against the system CA bundle (SSL_CERT_FILE
#     plus the usual system bundle paths, via lib/x509.rg) or an explicit PEM file
#   - SNI, ALPN ("h2" / "http/1.1"), and client certificates (mTLS)
#   - post-handshake: NewSessionTicket ignored, KeyUpdate supported
#
# Usage:
#   import tls
#   r = tls.connect("example.com", 443, 10000, True)
#   if r.ok {
#       c = r.conn
#       c.send("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
#       b = c.recv_bytes(4096)
#       if b.ok { print(b.value.to_str()) }
#       c.close()
#   } else {
#       print("tls failed:", r.error)
#   }
#
# Certificate verification:
#   - With verify=True, the certificate chain and hostname are verified.
#   - CA sources: an explicit ca_file (PEM), otherwise the system bundle
#     (SSL_CERT_FILE or the usual system bundle paths).
#   - verify=False skips chain and hostname verification but still checks the
#     CertificateVerify signature (proof of possession).
#   - When cert_file/key_file (PEM) are non-empty, a client certificate is sent
#     when the server requests one (mTLS). RSA and P-256 client keys are supported.
#
# The ssl/ctx fields are retained for API compatibility; ssl doubles as the
# open-connection marker (null when closed).

import net
import bytes
import bin
import sha2
import hmac
import hkdf
import aes
import chacha20poly1305 as cc
import x25519
import p256
import pkey
import x509
import asn1
import entropy
import time

# ---------------------------------------------------------------------------
# Small result / parse types
# ---------------------------------------------------------------------------

class TlsIo {
    ok: bool
    eof: bool
    error: str
    data: Bytes
}

class TlsRec {
    ok: bool
    eof: bool
    error: str
    typ: int
    data: Bytes
}

class TlsHs {
    ok: bool
    error: str
    typ: int
    body: Bytes
    raw: Bytes
}

class TlsCheck {
    ok: bool
    error: str
}

class TlsSh {
    ok: bool
    error: str
    is_hrr: bool
    has_version: bool
    suite: int
    group: int
    key: Bytes
    cookie: Bytes
}

class TlsEe {
    ok: bool
    error: str
    alpn: str
}

class TlsExt {
    ok: bool
    typ: int
    data: Bytes
    next: int
}

class TlsCertMsg {
    ok: bool
    error: str
    context: Bytes
    certs: List[Bytes]
}

class TlsPeer {
    ok: bool
    error: str
    spki: Bytes
}

class TlsCred {
    ok: bool
    error: str
    chain: List[Bytes]
    key: PrivateKey
}

# ---------------------------------------------------------------------------
# Byte helpers
# ---------------------------------------------------------------------------

def zero_bytes(n: int) -> Bytes {
    b = bytes.bytes_new(n)
    i = 0
    while i < n {
        b.push(0)
        i = i + 1
    }
    return b
}

def copy_bytes(b: @Bytes) -> Bytes {
    return b.slice(0, b.len)
}

def all_zero(b: @Bytes) -> bool {
    if b.len == 0 {
        return True
    }
    d = 0
    i = 0
    while i < b.len {
        d = d | b.get(i)
        i = i + 1
    }
    return d == 0
}

def is_ip_literal(host: str) -> bool {
    n = host.len()
    if n == 0 {
        return False
    }
    if host.contains(":") {
        return True
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

# ---------------------------------------------------------------------------
# Cipher-suite / hash plumbing
# ---------------------------------------------------------------------------

def suite_supported(suite: int) -> bool {
    return suite == 0x1301 or suite == 0x1302 or suite == 0x1303
}

def hash_len_for(suite: int) -> int {
    if suite == 0x1302 {
        return 48
    }
    return 32
}

def key_len_for(suite: int) -> int {
    if suite == 0x1301 {
        return 16
    }
    return 32
}

def hash_for_suite(suite: int, data: @Bytes) -> Bytes {
    if suite == 0x1302 {
        return sha2.sha384(data)
    }
    return sha2.sha256(data)
}

def hash_alg(alg: str, data: @Bytes) -> Bytes {
    if alg == "sha384" {
        return sha2.sha384(data)
    }
    if alg == "sha512" {
        return sha2.sha512(data)
    }
    return sha2.sha256(data)
}

def hmac_hash(suite: int, key: @Bytes, data: @Bytes) -> Bytes {
    if suite == 0x1302 {
        return hmac.sha384(key, data)
    }
    return hmac.sha256(key, data)
}

def hkdf_extract(suite: int, salt: @Bytes, ikm: @Bytes) -> Bytes {
    if suite == 0x1302 {
        return hkdf.extract_sha384(salt, ikm)
    }
    return hkdf.extract_sha256(salt, ikm)
}

def expand_label(suite: int, secret: @Bytes, label: str, context: @Bytes,
                 length: int) -> Bytes {
    if suite == 0x1302 {
        return hkdf.expand_label_sha384(secret, label, context, length)
    }
    return hkdf.expand_label_sha256(secret, label, context, length)
}

def derive_secret(suite: int, secret: @Bytes, label: str,
                  transcript: @Bytes) -> Bytes {
    th = hash_for_suite(suite, transcript)
    return expand_label(suite, secret, label, @th, hash_len_for(suite))
}

# Per-record nonce: static IV XOR the 64-bit sequence number (RFC 8446 5.3).
def record_nonce(iv: @Bytes, seq: int) -> Bytes {
    n = iv.slice(0, 12)
    i = 0
    while i < 8 {
        shift = 8 * i
        b = (seq >> shift) & 255
        idx = 11 - i
        n.set(idx, n.get(idx) ^ b)
        i = i + 1
    }
    return n
}

def aead_seal(suite: int, key: @Bytes, nonce: @Bytes, aad: @Bytes,
              plaintext: @Bytes) -> Bytes {
    if suite == 0x1303 {
        return cc.seal(key, nonce, aad, plaintext)
    }
    return aes.gcm_seal(key, nonce, aad, plaintext)
}

def aead_open(suite: int, key: @Bytes, nonce: @Bytes, aad: @Bytes,
              sealed: @Bytes) -> TlsIo {
    r = TlsIo()
    r.ok = False
    r.eof = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    if suite == 0x1303 {
        cr = cc.open(key, nonce, aad, sealed)
        r.ok = cr.ok
        r.error = cr.error
        r.data = cr.data
        return r
    }
    gr = aes.gcm_open(key, nonce, aad, sealed)
    r.ok = gr.ok
    r.error = gr.error
    r.data = gr.data
    return r
}

def alert_text(level: int, desc: int) -> str {
    if desc == 0 {
        return "tls close_notify"
    }
    if desc == 10 {
        return "tls alert: unexpected_message"
    }
    if desc == 20 {
        return "tls alert: bad_record_mac"
    }
    if desc == 22 {
        return "tls alert: record_overflow"
    }
    if desc == 40 {
        return "tls alert: handshake_failure"
    }
    if desc == 42 {
        return "tls alert: bad_certificate"
    }
    if desc == 43 {
        return "tls alert: unsupported_certificate"
    }
    if desc == 44 {
        return "tls alert: certificate_revoked"
    }
    if desc == 45 {
        return "tls alert: certificate_expired"
    }
    if desc == 46 {
        return "tls alert: certificate_unknown"
    }
    if desc == 47 {
        return "tls alert: illegal_parameter"
    }
    if desc == 48 {
        return "tls alert: unknown_ca"
    }
    if desc == 49 {
        return "tls alert: access_denied"
    }
    if desc == 50 {
        return "tls alert: decode_error"
    }
    if desc == 51 {
        return "tls alert: decrypt_error"
    }
    if desc == 70 {
        return "tls alert: protocol_version"
    }
    if desc == 71 {
        return "tls alert: insufficient_security"
    }
    if desc == 80 {
        return "tls alert: internal_error"
    }
    if desc == 90 {
        return "tls alert: user_canceled"
    }
    if desc == 109 {
        return "tls alert: missing_extension"
    }
    if desc == 110 {
        return "tls alert: unsupported_extension"
    }
    if desc == 112 {
        return "tls alert: unrecognized_name"
    }
    if desc == 116 {
        return "tls alert: certificate_required"
    }
    if desc == 120 {
        return "tls alert: no_application_protocol"
    }
    return "tls alert " + to_string(desc)
}

# ---------------------------------------------------------------------------
# ClientHello and ServerHello parsing
# ---------------------------------------------------------------------------

def append_ext(out: @var Bytes, typ: int, data: @Bytes) {
    bin.put_u16(out, typ)
    bin.put_u16(out, data.len)
    out.append(data)
}

def build_client_hello(server_name: str, offer_h2: bool, session_id: @Bytes,
                       random: @Bytes, hrr_group: int, cookie: @Bytes,
                       x_pub: @Bytes, p_pub: @Bytes) -> Bytes {
    exts = bytes.bytes_new(256)

    if server_name.len() > 0 and not is_ip_literal(server_name) {
        name = bytes.bytes_from_str(server_name)
        sni = bytes.bytes_new(0)
        bin.put_u16(sni, name.len + 3)
        bin.put_u8(sni, 0)
        bin.put_u16(sni, name.len)
        sni.append(@name)
        append_ext(@exts, 0, @sni)
    }

    groups = bytes.bytes_new(8)
    bin.put_u16(groups, 4)
    bin.put_u16(groups, 29)
    bin.put_u16(groups, 23)
    append_ext(@exts, 10, @groups)

    sigs = bytes.bytes_new(20)
    bin.put_u16(sigs, 16)
    bin.put_u16(sigs, 0x0804)   # rsa_pss_rsae_sha256
    bin.put_u16(sigs, 0x0805)   # rsa_pss_rsae_sha384
    bin.put_u16(sigs, 0x0806)   # rsa_pss_rsae_sha512
    bin.put_u16(sigs, 0x0403)   # ecdsa_secp256r1_sha256
    bin.put_u16(sigs, 0x0503)   # ecdsa_secp384r1_sha384
    bin.put_u16(sigs, 0x0401)   # rsa_pkcs1_sha256 (certificate chains)
    bin.put_u16(sigs, 0x0501)   # rsa_pkcs1_sha384
    bin.put_u16(sigs, 0x0601)   # rsa_pkcs1_sha512
    append_ext(@exts, 13, @sigs)

    shares = bytes.bytes_new(128)
    if hrr_group == 0 or hrr_group == 29 {
        e = bytes.bytes_new(0)
        bin.put_u16(e, 29)
        bin.put_u16(e, x_pub.len)
        e.append(x_pub)
        shares.append(@e)
    }
    if hrr_group == 0 or hrr_group == 23 {
        e = bytes.bytes_new(0)
        bin.put_u16(e, 23)
        bin.put_u16(e, p_pub.len)
        e.append(p_pub)
        shares.append(@e)
    }
    ks = bytes.bytes_new(0)
    bin.put_u16(ks, shares.len)
    ks.append(@shares)
    append_ext(@exts, 51, @ks)

    vers = bytes.bytes_new(3)
    bin.put_u8(vers, 2)
    bin.put_u16(vers, 0x0304)
    append_ext(@exts, 43, @vers)

    if offer_h2 {
        alpn = bytes.bytes_new(12)
        bin.put_u16(alpn, 12)
        bin.put_u8(alpn, 2)
        alpn.push(104)
        alpn.push(50)
        bin.put_u8(alpn, 8)
        alpn.push(104)
        alpn.push(116)
        alpn.push(116)
        alpn.push(112)
        alpn.push(47)
        alpn.push(49)
        alpn.push(46)
        alpn.push(49)
        append_ext(@exts, 16, @alpn)
    }

    if cookie.len > 0 {
        append_ext(@exts, 44, cookie)
    }

    suites = bytes.bytes_new(6)
    bin.put_u16(suites, 0x1301)
    bin.put_u16(suites, 0x1302)
    bin.put_u16(suites, 0x1303)

    body = bytes.bytes_new(256 + exts.len)
    bin.put_u16(body, 0x0303)
    body.append(random)
    bin.put_u8(body, session_id.len)
    body.append(session_id)
    bin.put_u16(body, suites.len)
    body.append(@suites)
    bin.put_u8(body, 1)
    bin.put_u8(body, 0)
    bin.put_u16(body, exts.len)
    body.append(@exts)

    msg = bytes.bytes_new(4 + body.len)
    msg.push(1)
    bin.put_u24(msg, body.len)
    msg.append(@body)
    return msg
}

def message_hash_msg(suite: int, first_ch: @Bytes) -> Bytes {
    h = hash_for_suite(suite, first_ch)
    m = bytes.bytes_new(4 + h.len)
    m.push(254)
    bin.put_u24(m, h.len)
    m.append(@h)
    return m
}

def hrr_random() -> Bytes {
    return bin.from_hex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")
}

def parse_server_hello(body: @Bytes) -> TlsSh {
    r = TlsSh()
    r.ok = False
    r.error = "bad ServerHello"
    r.is_hrr = False
    r.has_version = False
    r.suite = 0
    r.group = 0
    r.key = bytes.bytes_new(0)
    r.cookie = bytes.bytes_new(0)

    if body.len < 38 {
        return r
    }
    magic = hrr_random()
    hr = True
    i = 0
    while i < 32 {
        if body.get(2 + i) != magic.get(i) {
            hr = False
            break
        }
        i = i + 1
    }
    r.is_hrr = hr

    sid_len = body.get(34)
    p = 35 + sid_len
    if p + 3 > body.len {
        return r
    }
    r.suite = bin.u16(body, p)
    p = p + 3   # cipher suite + compression method
    if p + 2 > body.len {
        return r
    }
    elen = bin.u16(body, p)
    p = p + 2
    if p + elen > body.len {
        return r
    }
    end = p + elen
    while p + 4 <= end {
        typ = bin.u16(body, p)
        ln = bin.u16(body, p + 2)
        dpos = p + 4
        if dpos + ln > end {
            r.error = "bad ServerHello extensions"
            return r
        }
        if typ == 43 {
            if ln >= 2 and bin.u16(body, dpos) == 0x0304 {
                r.has_version = True
            }
        } elif typ == 51 {
            if r.is_hrr {
                if ln >= 2 {
                    r.group = bin.u16(body, dpos)
                }
            } else {
                if ln < 4 {
                    r.error = "bad key_share extension"
                    return r
                }
                r.group = bin.u16(body, dpos)
                klen = bin.u16(body, dpos + 2)
                if dpos + 4 + klen > end {
                    r.error = "bad key_share extension"
                    return r
                }
                r.key = body.slice(dpos + 4, dpos + 4 + klen)
            }
        } elif typ == 44 and r.is_hrr {
            r.cookie = body.slice(dpos, dpos + ln)
        }
        p = dpos + ln
    }
    r.ok = True
    r.error = ""
    return r
}

def parse_encrypted_extensions(body: @Bytes) -> TlsEe {
    r = TlsEe()
    r.ok = False
    r.error = "bad EncryptedExtensions"
    r.alpn = ""
    if body.len < 2 {
        return r
    }
    elen = bin.u16(body, 0)
    p = 2
    if p + elen > body.len {
        return r
    }
    end = p + elen
    while p + 4 <= end {
        typ = bin.u16(body, p)
        ln = bin.u16(body, p + 2)
        dpos = p + 4
        if dpos + ln > end {
            r.error = "bad EncryptedExtensions"
            return r
        }
        if typ == 16 {
            if ln < 3 {
                r.error = "bad ALPN extension"
                return r
            }
            plen = body.get(dpos + 2)
            if dpos + 3 + plen > end {
                r.error = "bad ALPN extension"
                return r
            }
            proto = body.slice(dpos + 3, dpos + 3 + plen)
            r.alpn = proto.to_str()
        }
        p = dpos + ln
    }
    r.ok = True
    r.error = ""
    return r
}

def certificate_request_context(body: @Bytes) -> Bytes {
    if body.len < 1 {
        return bytes.bytes_new(0)
    }
    n = body.get(0)
    if 1 + n > body.len {
        return bytes.bytes_new(0)
    }
    return body.slice(1, 1 + n)
}

def parse_certificate_msg(body: @Bytes) -> TlsCertMsg {
    r = TlsCertMsg()
    r.ok = False
    r.error = "bad Certificate message"
    r.context = bytes.bytes_new(0)
    r.certs = List[Bytes]()

    if body.len < 4 {
        return r
    }
    clen = body.get(0)
    p = 1 + clen
    if p + 3 > body.len {
        return r
    }
    r.context = body.slice(1, p)
    list_len = bin.u24(body, p)
    p = p + 3
    if p + list_len > body.len {
        return r
    }
    end = p + list_len
    while p < end {
        if p + 3 > end {
            r.error = "bad Certificate entry"
            return r
        }
        n = bin.u24(body, p)
        p = p + 3
        if p + n > end {
            r.error = "bad Certificate entry"
            return r
        }
        r.certs.push(body.slice(p, p + n))
        p = p + n
        if p + 2 > end {
            r.error = "bad Certificate entry extensions"
            return r
        }
        xlen = bin.u16(body, p)
        p = p + 2
        if p + xlen > end {
            r.error = "bad Certificate entry extensions"
            return r
        }
        p = p + xlen
    }
    r.ok = True
    r.error = ""
    return r
}

# ---------------------------------------------------------------------------
# Certificate verification helpers
# ---------------------------------------------------------------------------

def load_store(ca_file: str) -> X509Store {
    if ca_file.len() > 0 {
        st = x509.store_new()
        fr = bytes.read_bytes(ca_file)
        if fr.ok {
            data = fr.data
            n = x509.store_add_pem(@var st, @data)
        }
        return st
    }
    return x509.store_load_system()
}

def check_peer_cert(leaf_der: @Bytes, chain_der: @List[Bytes], host: str,
                    verify: bool, ca_file: str) -> TlsPeer {
    r = TlsPeer()
    r.ok = False
    r.error = ""
    r.spki = bytes.bytes_new(0)

    leaf = x509.parse(leaf_der)
    if not leaf.ok {
        r.error = "bad server certificate"
        return r
    }
    r.spki = leaf.spki
    if not verify {
        r.ok = True
        return r
    }

    st = load_store(ca_file)
    if st.certs.len() == 0 {
        r.error = "cannot load CA certificates"
        return r
    }
    chain = List[X509Cert]()
    i = 0
    while i < chain_der.len() {
        d = chain_der.get(i)
        c = x509.parse(@d)
        chain.push(c)
        i = i + 1
    }
    now = time.now()
    vr = x509.verify_chain(@leaf, @chain, @st, now)
    if not vr.ok {
        r.error = vr.error
        return r
    }
    if host.len() > 0 {
        if not x509.hostname_matches(@leaf, host) {
            r.error = "certificate hostname mismatch for " + host
            return r
        }
    }
    r.ok = True
    return r
}

def scheme_name(scheme: int) -> str {
    if scheme == 0x0403 {
        return "ecdsa_secp256r1_sha256"
    }
    if scheme == 0x0503 {
        return "ecdsa_secp384r1_sha384"
    }
    if scheme == 0x0804 {
        return "rsa_pss_rsae_sha256"
    }
    if scheme == 0x0805 {
        return "rsa_pss_rsae_sha384"
    }
    if scheme == 0x0806 {
        return "rsa_pss_rsae_sha512"
    }
    if scheme == 0x0401 {
        return "rsa_pkcs1_sha256"
    }
    if scheme == 0x0501 {
        return "rsa_pkcs1_sha384"
    }
    if scheme == 0x0601 {
        return "rsa_pkcs1_sha512"
    }
    return ""
}

def cv_content(server: bool, th: @Bytes) -> Bytes {
    label = "TLS 1.3, server CertificateVerify"
    if not server {
        label = "TLS 1.3, client CertificateVerify"
    }
    ctxb = bytes.bytes_from_str(label)
    out = bytes.bytes_new(64 + ctxb.len + 1 + th.len)
    i = 0
    while i < 64 {
        out.push(32)
        i = i + 1
    }
    out.append(@ctxb)
    out.push(0)
    out.append(th)
    return out
}

def verify_cv(scheme: int, sig: @Bytes, spki: @Bytes, th: @Bytes,
              server: bool) -> TlsCheck {
    r = TlsCheck()
    r.ok = False
    r.error = ""
    name = scheme_name(scheme)
    if name.len() == 0 {
        r.error = "server used an unsupported signature scheme"
        return r
    }
    alg = pkey.hash_for_scheme(name)
    if alg.len() == 0 {
        r.error = "server used an unsupported signature scheme"
        return r
    }
    content = cv_content(server, th)
    dg = hash_alg(alg, @content)
    kr = pkey.parse_spki(spki)
    if not kr.ok {
        r.error = "bad certificate public key: " + kr.error
        return r
    }
    key = kr.key
    if not pkey.scheme_fits_key(@key, name) {
        r.error = "certificate key does not fit the signature scheme"
        return r
    }
    if not pkey.verify(@key, name, @dg, sig) {
        r.error = "certificate verify signature check failed"
        return r
    }
    r.ok = True
    return r
}

def build_cert_msg(context: @Bytes, chain: @List[Bytes]) -> Bytes {
    entries = bytes.bytes_new(0)
    i = 0
    while i < chain.len() {
        c = chain.get(i)
        bin.put_u24(entries, c.len)
        entries.append(@c)
        bin.put_u16(entries, 0)
        i = i + 1
    }
    body = bytes.bytes_new(context.len + entries.len + 4)
    bin.put_u8(body, context.len)
    body.append(context)
    bin.put_u24(body, entries.len)
    body.append(@entries)
    msg = bytes.bytes_new(4 + body.len)
    msg.push(11)
    bin.put_u24(msg, body.len)
    msg.append(@body)
    return msg
}

def build_cv_msg(scheme: int, sig: @Bytes) -> Bytes {
    body = bytes.bytes_new(4 + sig.len)
    bin.put_u16(body, scheme)
    bin.put_u16(body, sig.len)
    body.append(sig)
    msg = bytes.bytes_new(4 + body.len)
    msg.push(15)
    bin.put_u24(msg, body.len)
    msg.append(@body)
    return msg
}

def load_client_cred(cert_file: str, key_file: str) -> TlsCred {
    r = TlsCred()
    r.ok = False
    r.error = ""
    r.chain = List[Bytes]()

    fr = bytes.read_bytes(cert_file)
    if not fr.ok {
        r.error = "cannot load client certificate"
        return r
    }
    data = fr.data
    pos = 0
    while True {
        blk = asn1.pem_next(@data, pos)
        if not blk.ok {
            break
        }
        pos = blk.next
        der = blk.der
        if blk.label == "CERTIFICATE" {
            r.chain.push(der)
        }
    }
    if r.chain.len() == 0 {
        r.error = "cannot load client certificate"
        return r
    }

    key_path = key_file
    if key_path.len() == 0 {
        key_path = cert_file
    }
    kfr = bytes.read_bytes(key_path)
    if not kfr.ok {
        r.error = "cannot load client private key"
        return r
    }
    kdata = kfr.data
    kpos = 0
    found = False
    while True {
        kb = asn1.pem_next(@kdata, kpos)
        if not kb.ok {
            break
        }
        kpos = kb.next
        kder = kb.der
        if kb.label == "PRIVATE KEY" or kb.label == "RSA PRIVATE KEY" or kb.label == "EC PRIVATE KEY" {
            pr = pkey.parse_private(@kder)
            if pr.ok {
                r.key = pr.key
                found = True
                break
            }
        }
    }
    if not found {
        r.error = "cannot load client private key"
        return r
    }
    r.ok = True
    return r
}

# ---------------------------------------------------------------------------
# Connection object
# ---------------------------------------------------------------------------

public class TlsConn {
    ssl: str
    ctx: str
    tcp: TcpStream
    timeout_ms: int
    alpn: str

    open: bool
    encrypted: bool
    out_encrypted: bool
    suite: int
    hash_len: int
    key_len: int
    in_secret: Bytes
    out_secret: Bytes
    in_key: Bytes
    in_iv: Bytes
    out_key: Bytes
    out_iv: Bytes
    in_seq: int
    out_seq: int
    read_buf: Bytes
    hs_buf: Bytes
    transcript: Bytes
    peer_closed: bool

    def send(self, data: str) -> int {
        return self.send_mem(data, data.len())
    }

    def send_bytes(self, data: @Bytes) -> int {
        return self.send_mem(data.data, data.len)
    }

    def send_mem(self, p: str, n: int) -> int {
        if not self.open or n <= 0 {
            return 0
        }
        data = bytes.bytes_from_mem(p, n)
        total = 0
        while total < data.len {
            k = data.len - total
            if k > 16384 {
                k = 16384
            }
            chunk = data.slice(total, total + k)
            wr = self.write_record(23, @chunk)
            if not wr.ok {
                return total
            }
            total = total + k
        }
        return total
    }

    def recv(self, max: int) -> TcpRecv {
        r = TcpRecv()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = ""
        b = self.recv_bytes(max)
        if not b.ok {
            r.ok = False
            r.error = b.error
            return r
        }
        if b.value.len > 0 {
            r.value = b.value.to_str()
        }
        return r
    }

    def recv_bytes(self, max: int) -> TcpRecvBytes {
        r = TcpRecvBytes()
        r.ok = True
        r.again = False
        r.error = ""
        r.value = bytes.bytes_new(0)
        if not self.open {
            r.ok = False
            r.error = "tls connection is closed"
            return r
        }
        if max <= 0 {
            return r
        }
        buf = self.read_buf
        if buf.len > 0 {
            k = buf.len
            if k > max {
                k = max
            }
            r.value = buf.slice(0, k)
            self.read_buf = buf.slice(k, buf.len)
            return r
        }
        while True {
            rec = self.read_record()
            if not rec.ok {
                r.ok = False
                r.error = rec.error
                return r
            }
            if rec.eof {
                self.peer_closed = True
                return r
            }
            if rec.typ == 23 {
                data = rec.data
                if data.len == 0 {
                    continue
                }
                k = data.len
                if k > max {
                    k = max
                }
                r.value = data.slice(0, k)
                if k < data.len {
                    self.read_buf = data.slice(k, data.len)
                }
                return r
            }
            if rec.typ == 21 {
                al = rec.data
                if al.len >= 2 {
                    desc = al.get(1)
                    if desc == 0 {
                        self.peer_closed = True
                        return r
                    }
                    r.ok = False
                    r.error = alert_text(al.get(0), desc)
                    return r
                }
                r.ok = False
                r.error = "tls alert"
                return r
            }
            if rec.typ == 22 {
                cur = self.hs_buf
                rd = rec.data
                cur.append(@rd)
                self.hs_buf = cur
                self.drain_post_hs()
            }
        }
    }

    def get_version(self) -> str {
        if not self.open {
            return ""
        }
        return "TLSv1.3"
    }

    def get_alpn(self) -> str {
        return self.alpn
    }

    def close(self) {
        if self.open and not self.peer_closed {
            al = bytes.bytes_new(2)
            al.push(1)
            al.push(0)
            self.write_record(21, @al)
        }
        self.open = False
        self.encrypted = False
        self.out_encrypted = False
        self.peer_closed = True
        self.ssl = ptr_null()
        self.tcp.close()
    }

    # ------------------------------------------------------------------
    # Record layer
    # ------------------------------------------------------------------

    def read_exact(self, n: int) -> TlsIo {
        r = TlsIo()
        r.ok = True
        r.eof = False
        r.error = ""
        out = bytes.bytes_new(n)
        while out.len < n {
            need = n - out.len
            rr = self.tcp.recv_bytes(need)
            if not rr.ok {
                r.ok = False
                r.error = rr.error
                r.data = out
                return r
            }
            v = rr.value
            if v.len == 0 {
                r.eof = True
                r.data = out
                return r
            }
            out.append(@v)
        }
        r.data = out
        return r
    }

    def read_record(self) -> TlsRec {
        r = TlsRec()
        r.ok = False
        r.eof = False
        r.error = ""
        r.typ = 0
        r.data = bytes.bytes_new(0)
        while True {
            h = self.read_exact(5)
            if not h.ok {
                r.error = h.error
                return r
            }
            if h.eof {
                r.ok = True
                r.eof = True
                return r
            }
            hd = h.data
            typ = hd.get(0)
            ln = bin.u16(hd, 3)
            if ln > 17408 {
                r.error = "tls record too large"
                return r
            }
            b = self.read_exact(ln)
            if not b.ok {
                r.error = b.error
                return r
            }
            if b.eof {
                r.error = "connection closed during tls record"
                return r
            }
            if typ == 20 {   # change_cipher_spec (TLS 1.3 middlebox compatibility)
                continue
            }
            body = b.data
            if not self.encrypted {
                r.ok = True
                r.typ = typ
                r.data = body
                return r
            }
            key = self.in_key
            iv = self.in_iv
            nonce = record_nonce(@iv, self.in_seq)
            aad = hd.slice(0, 5)
            op = aead_open(self.suite, @key, @nonce, @aad, @body)
            if not op.ok {
                r.error = "bad record MAC or corrupted record"
                return r
            }
            self.in_seq = self.in_seq + 1
            pt = op.data
            i = pt.len - 1
            while i >= 0 and pt.get(i) == 0 {
                i = i - 1
            }
            if i < 0 {
                r.error = "empty tls inner plaintext"
                return r
            }
            inner_type = pt.get(i)
            r.ok = True
            r.typ = inner_type
            r.data = pt.slice(0, i)
            return r
        }
    }

    def write_record(self, typ: int, payload: @Bytes) -> TlsIo {
        r = TlsIo()
        r.ok = False
        r.eof = False
        r.error = ""
        r.data = bytes.bytes_new(0)
        if self.tcp.fd < 0 {
            r.error = "socket is closed"
            return r
        }
        if self.out_encrypted {
            inner = bytes.bytes_new(payload.len + 1)
            inner.append(payload)
            inner.push(typ)
            hdr = bytes.bytes_new(5)
            hdr.push(23)
            hdr.push(3)
            hdr.push(3)
            bin.put_u16(hdr, inner.len + 16)
            key = self.out_key
            iv = self.out_iv
            nonce = record_nonce(@iv, self.out_seq)
            sealed = aead_seal(self.suite, @key, @nonce, @hdr, @inner)
            if sealed.len == 0 {
                r.error = "record encryption failed"
                return r
            }
            self.out_seq = self.out_seq + 1
            out = bytes.bytes_new(5 + sealed.len)
            out.append(@hdr)
            out.append(@sealed)
            n = self.tcp.send_bytes(@out)
            if n != out.len {
                r.error = "tls send failed"
                return r
            }
            r.ok = True
            return r
        }
        hdr = bytes.bytes_new(5)
        hdr.push(typ)
        hdr.push(3)
        hdr.push(1)
        bin.put_u16(hdr, payload.len)
        out = bytes.bytes_new(5 + payload.len)
        out.append(@hdr)
        out.append(payload)
        n = self.tcp.send_bytes(@out)
        if n != out.len {
            r.error = "tls send failed"
            return r
        }
        r.ok = True
        return r
    }

    # ------------------------------------------------------------------
    # Key schedule
    # ------------------------------------------------------------------

    def msg_hash(self) -> Bytes {
        tr = self.transcript
        return hash_for_suite(self.suite, @tr)
    }

    def set_read_keys(self, secret: @Bytes) {
        e = bytes.bytes_new(0)
        k = expand_label(self.suite, secret, "key", @e, self.key_len)
        iv = expand_label(self.suite, secret, "iv", @e, 12)
        self.in_secret = secret.slice(0, secret.len)
        self.in_key = k
        self.in_iv = iv
        self.in_seq = 0
    }

    def set_write_keys(self, secret: @Bytes) {
        e = bytes.bytes_new(0)
        k = expand_label(self.suite, secret, "key", @e, self.key_len)
        iv = expand_label(self.suite, secret, "iv", @e, 12)
        self.out_secret = secret.slice(0, secret.len)
        self.out_key = k
        self.out_iv = iv
        self.out_seq = 0
    }

    def update_read_keys(self) {
        s0 = self.in_secret
        e = bytes.bytes_new(0)
        s = expand_label(self.suite, @s0, "traffic upd", @e, self.hash_len)
        self.set_read_keys(@s)
    }

    def update_write_keys(self) {
        s0 = self.out_secret
        e = bytes.bytes_new(0)
        s = expand_label(self.suite, @s0, "traffic upd", @e, self.hash_len)
        self.set_write_keys(@s)
    }

    # ------------------------------------------------------------------
    # Handshake messages
    # ------------------------------------------------------------------

    def read_handshake(self) -> TlsHs {
        r = TlsHs()
        r.ok = False
        r.error = ""
        r.typ = 0
        r.body = bytes.bytes_new(0)
        r.raw = bytes.bytes_new(0)
        while True {
            b = self.hs_buf
            if b.len >= 4 {
                ln = (b.get(1) << 16) | (b.get(2) << 8) | b.get(3)
                if b.len >= 4 + ln {
                    r.typ = b.get(0)
                    r.raw = b.slice(0, 4 + ln)
                    r.body = b.slice(4, 4 + ln)
                    self.hs_buf = b.slice(4 + ln, b.len)
                    r.ok = True
                    return r
                }
            }
            rec = self.read_record()
            if not rec.ok {
                r.error = rec.error
                return r
            }
            if rec.eof {
                r.error = "connection closed during the tls handshake"
                return r
            }
            if rec.typ == 21 {
                al = rec.data
                if al.len >= 2 {
                    r.error = alert_text(al.get(0), al.get(1))
                } else {
                    r.error = "tls alert"
                }
                return r
            }
            if rec.typ != 22 {
                continue
            }
            cur = self.hs_buf
            rd = rec.data
            cur.append(@rd)
            self.hs_buf = cur
        }
    }

    def send_hs(self, msg: @Bytes) -> TlsIo {
        wr = self.write_record(22, msg)
        if wr.ok {
            self.transcript.append(msg)
        }
        return wr
    }

    def drain_post_hs(self) {
        while True {
            b = self.hs_buf
            if b.len < 4 {
                return
            }
            ln = (b.get(1) << 16) | (b.get(2) << 8) | b.get(3)
            if b.len < 4 + ln {
                return
            }
            typ = b.get(0)
            body = b.slice(4, 4 + ln)
            self.hs_buf = b.slice(4 + ln, b.len)
            if typ == 24 {
                req = 0
                if body.len > 0 {
                    req = body.get(0)
                }
                self.update_read_keys()
                if req == 1 {
                    self.update_write_keys()
                    ku = bytes.bytes_new(5)
                    ku.push(24)
                    bin.put_u24(ku, 1)
                    ku.push(0)
                    self.write_record(22, @ku)
                }
            }
        }
    }

    def hs_fail(self, msg: str, desc: int) -> TlsCheck {
        al = bytes.bytes_new(2)
        al.push(2)
        al.push(desc)
        if not self.peer_closed and self.tcp.fd >= 0 {
            self.write_record(21, @al)
        }
        r = TlsCheck()
        r.ok = False
        r.error = msg
        return r
    }

    def hs_ok(self) -> TlsCheck {
        r = TlsCheck()
        r.ok = True
        r.error = ""
        return r
    }

    # ------------------------------------------------------------------
    # TLS 1.3 handshake (client)
    # ------------------------------------------------------------------

    def handshake(self, server_name: str, verify: bool, ca_file: str,
                  offer_h2: bool, cred: @TlsCred) -> TlsCheck {
        x_kp = x25519.keypair()
        p_kp = p256.keypair()
        if x_kp.private_key.len != 32 or p_kp.private_key.len != 32 {
            return self.hs_fail("cannot generate a key share", 80)
        }
        session_id = entropy.bytes_random(32)
        random = entropy.bytes_random(32)
        if session_id.len != 32 or random.len != 32 {
            return self.hs_fail("no entropy available", 80)
        }
        x_priv = x_kp.private_key
        x_pub = x_kp.public_key
        p_priv = p_kp.private_key
        p_pub = p_kp.public_key
        if x_pub.len != 32 or p_pub.len != 65 {
            return self.hs_fail("cannot generate a key share", 80)
        }

        empty = bytes.bytes_new(0)
        ch = build_client_hello(server_name, offer_h2, @session_id, @random, 0,
                                @empty, @x_pub, @p_pub)
        self.transcript = ch.slice(0, ch.len)
        wr = self.write_record(22, @ch)
        if not wr.ok {
            return self.hs_fail(wr.error, 80)
        }

        shm = self.read_handshake()
        if not shm.ok {
            return self.hs_fail(shm.error, 40)
        }
        if shm.typ != 2 {
            return self.hs_fail("expected ServerHello", 10)
        }
        shbody = shm.body
        sh = parse_server_hello(@shbody)
        if not sh.ok {
            return self.hs_fail(sh.error, 50)
        }

        if sh.is_hrr {
            if not suite_supported(sh.suite) {
                return self.hs_fail("server selected an unsupported cipher suite", 40)
            }
            mh = message_hash_msg(sh.suite, @ch)
            self.transcript = mh.slice(0, mh.len)
            shraw = shm.raw
            self.transcript.append(@shraw)

            grp = sh.group
            if grp != 29 and grp != 23 {
                return self.hs_fail("server requested an unsupported key exchange group", 40)
            }
            ck = sh.cookie
            ch2 = build_client_hello(server_name, offer_h2, @session_id, @random,
                                     grp, @ck, @x_pub, @p_pub)
            wr = self.write_record(22, @ch2)
            if not wr.ok {
                return self.hs_fail(wr.error, 80)
            }
            self.transcript.append(@ch2)

            shm2 = self.read_handshake()
            if not shm2.ok {
                return self.hs_fail(shm2.error, 40)
            }
            if shm2.typ != 2 {
                return self.hs_fail("expected ServerHello after HelloRetryRequest", 10)
            }
            shbody = shm2.body
            sh = parse_server_hello(@shbody)
            if not sh.ok {
                return self.hs_fail(sh.error, 50)
            }
            if sh.is_hrr {
                return self.hs_fail("unexpected HelloRetryRequest", 47)
            }
            shraw = shm2.raw
            self.transcript.append(@shraw)
        } else {
            shraw = shm.raw
            self.transcript.append(@shraw)
        }

        if not suite_supported(sh.suite) {
            return self.hs_fail("server selected an unsupported cipher suite", 40)
        }
        if not sh.has_version {
            return self.hs_fail("server does not support TLS 1.3", 70)
        }
        if sh.group != 29 and sh.group != 23 {
            return self.hs_fail("server selected an unsupported key exchange group", 40)
        }

        sk = sh.key
        ss = bytes.bytes_new(0)
        if sh.group == 29 {
            if sk.len != 32 {
                return self.hs_fail("bad x25519 key share", 47)
            }
            ss = x25519.shared_secret(@x_priv, @sk)
        } else {
            ss = p256.shared_secret(@p_priv, @sk)
        }
        if ss.len == 0 or all_zero(@ss) {
            return self.hs_fail("key exchange failed", 40)
        }

        suite = sh.suite
        hl = hash_len_for(suite)
        kl = key_len_for(suite)
        self.suite = suite
        self.hash_len = hl
        self.key_len = kl

        zeros = zero_bytes(hl)
        early = hkdf_extract(suite, @zeros, @zeros)
        derived = derive_secret(suite, @early, "derived", @empty)
        hs_secret = hkdf_extract(suite, @derived, @ss)

        th = self.msg_hash()
        c_hs = expand_label(suite, @hs_secret, "c hs traffic", @th, hl)
        s_hs = expand_label(suite, @hs_secret, "s hs traffic", @th, hl)
        c_fin = expand_label(suite, @c_hs, "finished", @empty, hl)
        s_fin = expand_label(suite, @s_hs, "finished", @empty, hl)
        self.set_read_keys(@s_hs)
        self.set_write_keys(@c_hs)
        self.encrypted = True
        self.out_encrypted = True

        derived2 = derive_secret(suite, @hs_secret, "derived", @empty)
        master = hkdf_extract(suite, @derived2, @zeros)

        # EncryptedExtensions
        m = self.read_handshake()
        if not m.ok {
            return self.hs_fail(m.error, 40)
        }
        if m.typ != 8 {
            return self.hs_fail("expected EncryptedExtensions", 10)
        }
        mb = m.body
        mraw = m.raw
        self.transcript.append(@mraw)
        ex = parse_encrypted_extensions(@mb)
        if not ex.ok {
            return self.hs_fail(ex.error, 50)
        }
        self.alpn = ex.alpn

        # Optional CertificateRequest
        req_ctx = empty
        m = self.read_handshake()
        if not m.ok {
            return self.hs_fail(m.error, 40)
        }
        requested = False
        if m.typ == 13 {
            requested = True
            mb = m.body
            req_ctx = certificate_request_context(@mb)
            mraw = m.raw
            self.transcript.append(@mraw)
            m = self.read_handshake()
            if not m.ok {
                return self.hs_fail(m.error, 40)
            }
        }
        if m.typ != 11 {
            return self.hs_fail("expected Certificate", 10)
        }
        mb = m.body
        mraw = m.raw
        self.transcript.append(@mraw)
        cm = parse_certificate_msg(@mb)
        if not cm.ok {
            return self.hs_fail(cm.error, 50)
        }
        if cm.certs.len() == 0 {
            return self.hs_fail("server sent an empty certificate chain", 42)
        }

        leaf_der = cm.certs.get(0)
        chain_der = List[Bytes]()
        i = 1
        while i < cm.certs.len() {
            chain_der.push(cm.certs.get(i))
            i = i + 1
        }
        peer = check_peer_cert(@leaf_der, @chain_der, server_name, verify, ca_file)
        if not peer.ok {
            return self.hs_fail(peer.error, 42)
        }
        spki = peer.spki

        # CertificateVerify
        m = self.read_handshake()
        if not m.ok {
            return self.hs_fail(m.error, 40)
        }
        if m.typ != 15 {
            return self.hs_fail("expected CertificateVerify", 10)
        }
        th_cert = self.msg_hash()
        mb = m.body
        mraw = m.raw
        self.transcript.append(@mraw)
        if mb.len < 4 {
            return self.hs_fail("bad CertificateVerify", 50)
        }
        scheme = bin.u16(mb, 0)
        slen = bin.u16(mb, 2)
        if 4 + slen > mb.len {
            return self.hs_fail("bad CertificateVerify", 50)
        }
        sig = mb.slice(4, 4 + slen)
        vr = verify_cv(scheme, @sig, @spki, @th_cert, True)
        if not vr.ok {
            return self.hs_fail(vr.error, 42)
        }

        # server Finished
        m = self.read_handshake()
        if not m.ok {
            return self.hs_fail(m.error, 40)
        }
        if m.typ != 20 {
            return self.hs_fail("expected Finished", 10)
        }
        th_fin = self.msg_hash()
        expect = hmac_hash(suite, @s_fin, @th_fin)
        mb = m.body
        if not bin.equal(@expect, @mb) {
            return self.hs_fail("server Finished verification failed", 51)
        }
        mraw = m.raw
        self.transcript.append(@mraw)

        # Application traffic keys.
        th_sf = self.msg_hash()
        c_ap = expand_label(suite, @master, "c ap traffic", @th_sf, hl)
        s_ap = expand_label(suite, @master, "s ap traffic", @th_sf, hl)
        self.set_read_keys(@s_ap)

        # Client flight.
        sent_cert = False
        if requested and cred.ok {
            chain = cred.chain
            cmsg = build_cert_msg(@req_ctx, @chain)
            wr = self.send_hs(@cmsg)
            if not wr.ok {
                return self.hs_fail(wr.error, 80)
            }
            ckey = cred.key
            ckind = ckey.kind
            cscheme = 0
            cname = ""
            if ckind == "rsa" {
                cscheme = 0x0804
                cname = "rsa_pss_rsae_sha256"
            } elif ckind == "ec256" {
                cscheme = 0x0403
                cname = "ecdsa_secp256r1_sha256"
            } else {
                return self.hs_fail("unsupported client private key type", 40)
            }
            th_cc = self.msg_hash()
            sig_in = cv_content(False, @th_cc)
            cdigest = hash_alg(pkey.hash_for_scheme(cname), @sig_in)
            csig = pkey.sign(@ckey, cname, @cdigest)
            if csig.len == 0 {
                return self.hs_fail("client certificate signing failed", 80)
            }
            cvmsg = build_cv_msg(cscheme, @csig)
            wr = self.send_hs(@cvmsg)
            if not wr.ok {
                return self.hs_fail(wr.error, 80)
            }
            sent_cert = True
        } elif requested {
            empty_chain = List[Bytes]()
            cmsg = build_cert_msg(@req_ctx, @empty_chain)
            wr = self.send_hs(@cmsg)
            if not wr.ok {
                return self.hs_fail(wr.error, 80)
            }
        }

        th_cf = self.msg_hash()
        cvd = hmac_hash(suite, @c_fin, @th_cf)
        fin = bytes.bytes_new(4 + cvd.len)
        fin.push(20)
        bin.put_u24(fin, cvd.len)
        fin.append(@cvd)
        wr = self.send_hs(@fin)
        if not wr.ok {
            return self.hs_fail(wr.error, 80)
        }

        self.set_write_keys(@c_ap)
        self.open = True
        self.ssl = int_to_ptr(1)
        return self.hs_ok()
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

public class TlsResult {
    ok: bool
    error: str
    conn: TlsConn
}

def empty_tcp() -> TcpStream {
    t = TcpStream()
    t.fd = -1
    t.timeout_ms = 0
    return t
}

def empty_conn(tcp: TcpStream) -> TlsConn {
    c = TlsConn()
    c.ssl = ptr_null()
    c.ctx = ptr_null()
    c.tcp = tcp
    c.timeout_ms = 0
    c.alpn = ""
    c.open = False
    c.encrypted = False
    c.out_encrypted = False
    c.suite = 0
    c.hash_len = 32
    c.key_len = 16
    c.in_secret = bytes.bytes_new(0)
    c.out_secret = bytes.bytes_new(0)
    c.in_key = bytes.bytes_new(0)
    c.in_iv = bytes.bytes_new(0)
    c.out_key = bytes.bytes_new(0)
    c.out_iv = bytes.bytes_new(0)
    c.in_seq = 0
    c.out_seq = 0
    c.read_buf = bytes.bytes_new(0)
    c.hs_buf = bytes.bytes_new(0)
    c.transcript = bytes.bytes_new(0)
    c.peer_closed = True
    return c
}

def fail_result(msg: str) -> TlsResult {
    r = TlsResult()
    r.ok = False
    r.error = msg
    r.conn = empty_conn(empty_tcp())
    return r
}

def empty_cred() -> TlsCred {
    r = TlsCred()
    r.ok = False
    r.error = ""
    r.chain = List[Bytes]()
    return r
}

# TLS handshake over an already-established TCP connection (HTTP proxy CONNECT / existing socket scenarios).
# When ca_file is empty, the system CA bundle is used (SSL_CERT_FILE or the usual bundle paths).
# When cert_file/key_file are non-empty, a client certificate is enabled (mTLS); an empty key_file reuses cert_file.
# With offer_h2=True, ALPN offers "h2" and "http/1.1"; the result is read from TlsConn.alpn.
public def connect_on_alpn(tcp: TcpStream, server_name: str, verify: bool,
                           ca_file: str, cert_file: str, key_file: str,
                           timeout_ms: int, offer_h2: bool) -> TlsResult {
    if tcp.fd < 0 {
        return fail_result("socket is closed")
    }
    if key_file.len() > 0 and cert_file.len() == 0 {
        tcp.close()
        return fail_result("client key without certificate")
    }
    cred = empty_cred()
    if cert_file.len() > 0 {
        cred = load_client_cred(cert_file, key_file)
        if not cred.ok {
            tcp.close()
            return fail_result(cred.error)
        }
    }

    c = empty_conn(tcp)
    c.timeout_ms = timeout_ms
    hs = c.handshake(server_name, verify, ca_file, offer_h2, @cred)
    if not hs.ok {
        c.close()
        return fail_result(hs.error)
    }
    r = TlsResult()
    r.ok = True
    r.error = ""
    r.conn = c
    return r
}

# Handshake over an existing TCP connection, without a client certificate or ALPN negotiation.
public def connect_on_mtls(tcp: TcpStream, server_name: str, verify: bool,
                           ca_file: str, cert_file: str, key_file: str,
                           timeout_ms: int) -> TlsResult {
    return connect_on_alpn(tcp, server_name, verify, ca_file, cert_file, key_file,
                           timeout_ms, False)
}

# Handshake over an existing TCP connection, without a client certificate.
public def connect_on(tcp: TcpStream, server_name: str, verify: bool,
                      ca_file: str, timeout_ms: int) -> TlsResult {
    return connect_on_mtls(tcp, server_name, verify, ca_file, "", "", timeout_ms)
}

# New connection plus handshake; enables a client certificate when cert_file/key_file are non-empty.
public def connect_mtls(host: str, port: int, timeout_ms: int, verify: bool,
                        ca_file: str, cert_file: str, key_file: str) -> TlsResult {
    return connect_alpn(host, port, timeout_ms, verify, ca_file, cert_file, key_file,
                        False)
}

# New connection plus handshake; with offer_h2=True, ALPN negotiation starts ("h2" preferred).
public def connect_alpn(host: str, port: int, timeout_ms: int, verify: bool,
                        ca_file: str, cert_file: str, key_file: str,
                        offer_h2: bool) -> TlsResult {
    c = net.connect_to_timeout(host, port, timeout_ms)
    if not c.ok {
        return fail_result(c.error)
    }
    return connect_on_alpn(c.stream, host, verify, ca_file, cert_file, key_file,
                           timeout_ms, offer_h2)
}

public def connect_with_ca(host: str, port: int, timeout_ms: int, verify: bool,
                           ca_file: str) -> TlsResult {
    return connect_mtls(host, port, timeout_ms, verify, ca_file, "", "")
}

public def connect(host: str, port: int, timeout_ms: int, verify: bool) -> TlsResult {
    return connect_with_ca(host, port, timeout_ms, verify, "")
}
