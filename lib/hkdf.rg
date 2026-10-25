# RGC standard library: hkdf
#
# HKDF (RFC 5869) over SHA-256 / SHA-384 and the TLS 1.3 HKDF-Expand-Label
# wrapper (RFC 8446 section 7.1). Pure RGC on top of lib/hmac.rg.
#
# Usage:
#   import hkdf
#   prk = hkdf.extract_sha256(@salt, @ikm)
#   okm = hkdf.expand_sha256(@prk, @info, 32)
#   key = hkdf.expand_label_sha256(@secret, "key", @empty, 16)

import bytes
import bin
import hmac

public def extract_sha256(salt: @Bytes, ikm: @Bytes) -> Bytes {
    return hmac.sha256(salt, ikm)
}

public def extract_sha384(salt: @Bytes, ikm: @Bytes) -> Bytes {
    return hmac.sha384(salt, ikm)
}

public def expand_sha256(prk: @Bytes, info: @Bytes, length: int) -> Bytes {
    out = bytes.bytes_new(length)
    t = bytes.bytes_new(0)
    counter = 1
    while out.len < length {
        ctr = bytes.bytes_new(1)
        ctr.push(counter & 255)
        nt = hmac.sha256_parts(prk, @t, info, @ctr)
        n = nt.len
        if out.len + n > length {
            n = length - out.len
        }
        out.append_mem(nt.data, n)
        t = nt
        counter = counter + 1
    }
    return out
}

public def expand_sha384(prk: @Bytes, info: @Bytes, length: int) -> Bytes {
    out = bytes.bytes_new(length)
    t = bytes.bytes_new(0)
    counter = 1
    while out.len < length {
        ctr = bytes.bytes_new(1)
        ctr.push(counter & 255)
        nt = hmac.sha384_parts(prk, @t, info, @ctr)
        n = nt.len
        if out.len + n > length {
            n = length - out.len
        }
        out.append_mem(nt.data, n)
        t = nt
        counter = counter + 1
    }
    return out
}

def label_info(label: str, context: @Bytes, length: int) -> Bytes {
    full = "tls13 " + label
    info = bytes.bytes_new(full.len() + context.len + 4)
    bin.put_u16(info, length)
    bin.put_u8(info, full.len())
    info.append_mem(full, full.len())
    bin.put_u8(info, context.len)
    info.append(context)
    return info
}

public def expand_label_sha256(secret: @Bytes, label: str, context: @Bytes,
                               length: int) -> Bytes {
    info = label_info(label, context, length)
    return expand_sha256(secret, @info, length)
}

public def expand_label_sha384(secret: @Bytes, label: str, context: @Bytes,
                               length: int) -> Bytes {
    info = label_info(label, context, length)
    return expand_sha384(secret, @info, length)
}
