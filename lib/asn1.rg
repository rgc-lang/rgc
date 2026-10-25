# RGC standard library: asn1
#
# Minimal DER reader plus PEM/base64 decoding used by the X.509 and key-parsing
# code (TLS certificate chains, RSA/EC private keys, system CA bundles).
#
# Usage:
#   import asn1
#   t = asn1.der_next(@der, 0)
#   pos = t.start
#   while pos < t.start + t.len {
#       c = asn1.der_next(@der, pos)
#       ...
#       pos = c.next
#   }
#
# Notes:
#   - Definite lengths only (DER); multi-byte tags are rejected.
#   - der_next never panics on malformed input; ok=False marks a parse error.
#   - Base64 decoding ignores whitespace and other non-alphabet bytes, so PEM
#     bodies can be fed in directly regardless of line endings.

import bytes

public class Tlv {
    ok: bool
    tag: int
    start: int
    len: int
    next: int
}

public def der_next(data: @Bytes, pos: int) -> Tlv {
    t = Tlv()
    t.ok = False
    t.tag = 0
    t.start = 0
    t.len = 0
    t.next = pos
    if pos < 0 or pos >= data.len {
        return t
    }
    tag = data.get(pos)
    if tag & 31 == 31 {
        return t
    }
    p = pos + 1
    if p >= data.len {
        return t
    }
    b = data.get(p)
    p = p + 1
    n = 0
    if b < 128 {
        n = b
    } else {
        k = b & 127
        if k == 0 or k > 4 {
            return t
        }
        i = 0
        while i < k {
            if p >= data.len {
                return t
            }
            n = (n << 8) | data.get(p)
            p = p + 1
            i = i + 1
        }
    }
    if p + n > data.len {
        return t
    }
    t.ok = True
    t.tag = tag
    t.start = p
    t.len = n
    t.next = p + n
    return t
}

public def der_is_constructed(tag: int) -> bool {
    return tag & 32 != 0
}

public def der_is_context(tag: int) -> bool {
    return tag & 192 == 128
}

public def der_context_index(tag: int) -> int {
    return tag & 31
}

# Content bytes of an OCTET STRING / BIT STRING / INTEGER element.
public def der_content(data: @Bytes, t: @Tlv) -> Bytes {
    return data.slice(t.start, t.start + t.len)
}

def oid_to_str(data: @Bytes, t: @Tlv) -> str {
    if t.len <= 0 {
        return ""
    }
    b0 = data.get(t.start)
    x = b0 / 40
    y = b0 % 40
    if x > 2 {
        x = 2
        y = b0 - 80
    }
    out = to_string(x) + "." + to_string(y)
    v = 0
    i = t.start + 1
    end = t.start + t.len
    while i < end {
        c = data.get(i)
        v = v * 128 + (c & 127)
        if c < 128 {
            out = out + "." + to_string(v)
            v = 0
        }
        i = i + 1
    }
    return out
}

public def der_oid_is(data: @Bytes, t: @Tlv, dotted: str) -> bool {
    if t.tag != 6 {
        return False
    }
    return oid_to_str(data, t) == dotted
}

public def der_oid_str(data: @Bytes, t: @Tlv) -> str {
    return oid_to_str(data, t)
}

def b64_val(c: int) -> int {
    if c >= 65 and c <= 90 {
        return c - 65
    }
    if c >= 97 and c <= 122 {
        return c - 97 + 26
    }
    if c >= 48 and c <= 57 {
        return c - 48 + 52
    }
    if c == 43 {
        return 62
    }
    if c == 47 {
        return 63
    }
    return -1
}

public def base64_decode(text: str) -> Bytes {
    out = bytes.bytes_new(text.len() * 3 / 4 + 3)
    acc = 0
    bits = 0
    i = 0
    while i < text.len() {
        v = b64_val(text.char_at(i))
        if v >= 0 {
            acc = ((acc << 6) | v) & 16777215
            bits = bits + 6
            if bits >= 8 {
                bits = bits - 8
                out.push((acc >> bits) & 255)
            }
        }
        i = i + 1
    }
    return out
}

public class PemBlock {
    ok: bool
    label: str
    der: Bytes
    next: int
}

def pem_blank() -> PemBlock {
    r = PemBlock()
    r.ok = False
    r.label = ""
    r.der = bytes.bytes_new(0)
    r.next = 0
    return r
}

# Decode the first PEM block at or after pos. next is the offset just past the
# END line, so callers can loop to walk a CA bundle.
public def pem_next(text: @Bytes, pos: int) -> PemBlock {
    r = pem_blank()
    r.next = text.len
    bpos = text.find("-----BEGIN ", pos)
    if bpos < 0 {
        return r
    }
    ls = bpos + 11
    le = text.find("-----", ls)
    if le < 0 {
        return r
    }
    label_b = text.slice(ls, le)
    body_start = text.find("\n", le)
    if body_start < 0 {
        return r
    }
    epos = text.find("-----END ", body_start)
    if epos < 0 {
        return r
    }
    body_b = text.slice(body_start + 1, epos)
    body = body_b.to_str()
    der = base64_decode(body)
    tail = text.find("-----", epos + 9)
    if tail >= 0 {
        r.next = tail + 5
    }
    if der.len == 0 {
        return r
    }
    r.ok = True
    r.label = label_b.to_str()
    r.der = der
    return r
}
