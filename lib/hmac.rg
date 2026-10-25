# RGC standard library: hmac
#
# HMAC (RFC 2104) over SHA-256 and SHA-384, implemented with lib/sha2.rg.
#
# Usage:
#   import hmac
#   mac = hmac.sha256(@key, @message)
#   mac = hmac.sha384_parts(@key, @part1, @part2)

import bytes
import sha2

def pad_key(key: @Bytes, block: int, hash_len: int) -> Bytes {
    k = bytes.bytes_new(block)
    if key.len > block {
        if hash_len == 32 {
            d = sha2.sha256(key)
            k.append(@d)
        } else {
            d = sha2.sha384(key)
            k.append(@d)
        }
    } else {
        k.append(key)
    }
    k.len = block
    return k
}

def inner_pad(k: @Bytes) -> Bytes {
    p = bytes.bytes_new(k.len)
    i = 0
    while i < k.len {
        p.push(k.get(i) ^ 54)
        i = i + 1
    }
    return p
}

def outer_pad(k: @Bytes) -> Bytes {
    p = bytes.bytes_new(k.len)
    i = 0
    while i < k.len {
        p.push(k.get(i) ^ 92)
        i = i + 1
    }
    return p
}

public def sha256_parts(key: @Bytes, p1: @Bytes, p2: @Bytes, p3: @Bytes) -> Bytes {
    k = pad_key(key, 64, 32)
    ip = inner_pad(@k)
    op = outer_pad(@k)
    si = sha2.sha256_new()
    sha2.sha256_update(@var si, @ip)
    sha2.sha256_update(@var si, p1)
    sha2.sha256_update(@var si, p2)
    sha2.sha256_update(@var si, p3)
    inner = sha2.sha256_finish(@var si)
    so = sha2.sha256_new()
    sha2.sha256_update(@var so, @op)
    sha2.sha256_update(@var so, @inner)
    return sha2.sha256_finish(@var so)
}

public def sha384_parts(key: @Bytes, p1: @Bytes, p2: @Bytes, p3: @Bytes) -> Bytes {
    k = pad_key(key, 128, 48)
    ip = inner_pad(@k)
    op = outer_pad(@k)
    si = sha2.sha384_new()
    sha2.sha512_update(@var si, @ip)
    sha2.sha512_update(@var si, p1)
    sha2.sha512_update(@var si, p2)
    sha2.sha512_update(@var si, p3)
    inner = sha2.sha512_finish(@var si)
    so = sha2.sha384_new()
    sha2.sha512_update(@var so, @op)
    sha2.sha512_update(@var so, @inner)
    return sha2.sha512_finish(@var so)
}

public def sha256(key: @Bytes, data: @Bytes) -> Bytes {
    empty = bytes.bytes_new(0)
    return sha256_parts(key, data, @empty, @empty)
}

public def sha384(key: @Bytes, data: @Bytes) -> Bytes {
    empty = bytes.bytes_new(0)
    return sha384_parts(key, data, @empty, @empty)
}
