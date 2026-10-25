# RGC standard library: bigint
#
# Unsigned big integers and Montgomery modular arithmetic used by the public-key
# code (X25519, P-256, RSA). Limbs are 16-bit little-endian values stored in an
# i64 List, so every product fits comfortably in i64.
#
# Usage:
#   import bigint as bn
#   m = bn.from_hex("ffffffff00000001...", 16)
#   mc = bn.mont_new(@m)
#   x = bn.mont_from(@mc, @a)
#   y = bn.mont_mul(@mc, @x, @x)
#   z = bn.mont_to(@mc, @y)
#
# Notes:
#   - The modulus must be odd (all crypto moduli are) and fit exactly in n limbs.
#   - mont_new computes R = 2^(16n) mod m, R^2 mod m and -m^-1 mod 2^16.
#   - Values passed to mont_mul must be reduced (< m); mont_from reduces its input.
#   - This is not constant-time for comparisons/subtractions, but multiplication
#     and reduction do not branch on limb values.

import bytes
import bin

public class Big {
    n: int
    d: List[int]
}

public def big_new(n: int) -> Big {
    b = Big()
    b.n = n
    b.d = List[int]()
    i = 0
    while i < n {
        b.d.push(0)
        i = i + 1
    }
    return b
}

public def big_from_int(v: int, n: int) -> Big {
    b = big_new(n)
    x = v
    i = 0
    while i < n and x > 0 {
        b.d.set(i, x & 65535)
        x = x >> 16
        i = i + 1
    }
    return b
}

public def big_copy(a: @Big) -> Big {
    b = big_new(a.n)
    i = 0
    while i < a.n {
        b.d.set(i, a.d.get(i))
        i = i + 1
    }
    return b
}

public def big_from_bytes_be(data: @Bytes, n: int) -> Big {
    b = big_new(n)
    i = 0
    while i < n {
        lo_pos = data.len - 1 - i * 2
        if lo_pos < 0 {
            return b
        }
        lo = data.get(lo_pos)
        hi = 0
        if lo_pos - 1 >= 0 {
            hi = data.get(lo_pos - 1)
        }
        b.d.set(i, (hi << 8) | lo)
        i = i + 1
    }
    return b
}

public def big_from_bytes_le(data: @Bytes, n: int) -> Big {
    b = big_new(n)
    i = 0
    while i < n {
        lo_pos = i * 2
        if lo_pos >= data.len {
            return b
        }
        lo = data.get(lo_pos)
        hi = 0
        if lo_pos + 1 < data.len {
            hi = data.get(lo_pos + 1)
        }
        b.d.set(i, (hi << 8) | lo)
        i = i + 1
    }
    return b
}

public def big_to_bytes_le(a: @Big, nbytes: int) -> Bytes {
    out = bytes.bytes_new(nbytes)
    i = 0
    while i < nbytes {
        limb_index = i / 2
        v = 0
        if limb_index < a.n {
            v = a.d.get(limb_index)
        }
        if i % 2 == 0 {
            out.push(v & 255)
        } else {
            out.push((v >> 8) & 255)
        }
        i = i + 1
    }
    return out
}

public def big_to_bytes_be(a: @Big, nbytes: int) -> Bytes {
    out = bytes.bytes_new(nbytes)
    i = 0
    while i < nbytes {
        limb_index = nbytes / 2 - 1 - i / 2
        v = 0
        if limb_index >= 0 and limb_index < a.n {
            v = a.d.get(limb_index)
        }
        if i % 2 == 0 {
            out.push((v >> 8) & 255)
        } else {
            out.push(v & 255)
        }
        i = i + 1
    }
    return out
}

public def from_hex(s: str, n: int) -> Big {
    data = bin.from_hex(s)
    return big_from_bytes_be(@data, n)
}

public def to_hex(a: @Big) -> str {
    data = big_to_bytes_be(a, a.n * 2)
    return bin.to_hex(@data)
}

public def big_cmp(a: @Big, b: @Big) -> int {
    i = a.n - 1
    if b.n - 1 > i {
        i = b.n - 1
    }
    while i >= 0 {
        x = 0
        if i < a.n {
            x = a.d.get(i)
        }
        y = 0
        if i < b.n {
            y = b.d.get(i)
        }
        if x < y {
            return -1
        }
        if x > y {
            return 1
        }
        i = i - 1
    }
    return 0
}

public def big_is_zero(a: @Big) -> bool {
    i = 0
    while i < a.n {
        if a.d.get(i) != 0 {
            return False
        }
        i = i + 1
    }
    return True
}

public def big_bit_len(a: @Big) -> int {
    i = a.n - 1
    while i >= 0 {
        v = a.d.get(i)
        if v != 0 {
            bits = 0
            while v > 0 {
                bits = bits + 1
                v = v >> 1
            }
            return i * 16 + bits
        }
        i = i - 1
    }
    return 0
}

public def big_shr(a: @Big, bits: int) -> Big {
    b = big_new(a.n)
    limb_shift = bits / 16
    bit_shift = bits % 16
    i = 0
    while i < a.n {
        src = i + limb_shift
        v = 0
        if src < a.n {
            v = a.d.get(src) >> bit_shift
            if bit_shift > 0 and src + 1 < a.n {
                v = v | ((a.d.get(src + 1) << (16 - bit_shift)) & 65535)
            }
        }
        b.d.set(i, v)
        i = i + 1
    }
    return b
}

public def big_bit(a: @Big, bit: int) -> int {
    limb = bit / 16
    if limb >= a.n {
        return 0
    }
    return (a.d.get(limb) >> (bit % 16)) & 1
}

# r = v mod m for v < 2^(16*n) with n = m.n; one subtraction is enough
# when v < 2m, and this helper is only used with that bound.
def reduce_scratch(t: @List[int], m: @Big) -> Big {
    n = m.n
    guard = 0
    while guard < 4 {
        ge = t.get(n) != 0
        if not ge {
            i = n - 1
            while i >= 0 {
                tv = t.get(i)
                mv = m.d.get(i)
                if tv > mv {
                    ge = True
                    i = -2
                } elif tv < mv {
                    i = -2
                } else {
                    i = i - 1
                }
            }
            if i == -1 {
                ge = True
            }
        }
        if not ge {
            break
        }
        borrow = 0
        i = 0
        while i < n {
            cur = t.get(i) - m.d.get(i) - borrow
            if cur < 0 {
                cur = cur + 65536
                borrow = 1
            } else {
                borrow = 0
            }
            t.set(i, cur)
            i = i + 1
        }
        t.set(n, t.get(n) - borrow)
        guard = guard + 1
    }
    r = big_new(n)
    i = 0
    while i < n {
        r.d.set(i, t.get(i))
        i = i + 1
    }
    return r
}

def add_scratch(a: @Big, b: @Big) -> List[int] {
    t = List[int]()
    carry = 0
    i = 0
    while i < a.n {
        cur = a.d.get(i) + b.d.get(i) + carry
        t.push(cur & 65535)
        carry = cur >> 16
        i = i + 1
    }
    t.push(carry)
    return t
}

public def big_add_mod(a: @Big, b: @Big, m: @Big) -> Big {
    t = add_scratch(@a, @b)
    return reduce_scratch(@t, m)
}

public def big_sub_mod(a: @Big, b: @Big, m: @Big) -> Big {
    r = big_new(a.n)
    borrow = 0
    i = 0
    while i < a.n {
        cur = a.d.get(i) - b.d.get(i) - borrow
        if cur < 0 {
            cur = cur + 65536
            borrow = 1
        } else {
            borrow = 0
        }
        r.d.set(i, cur)
        i = i + 1
    }
    if borrow != 0 {
        carry = 0
        i = 0
        while i < a.n {
            cur = r.d.get(i) + m.d.get(i) + carry
            r.d.set(i, cur & 65535)
            carry = cur >> 16
            i = i + 1
        }
    }
    return r
}

public def big_sub_small(a: @Big, v: int) -> Big {
    r = big_copy(@a)
    borrow = v
    i = 0
    while i < r.n and borrow > 0 {
        cur = r.d.get(i) - (borrow & 65535)
        borrow = borrow >> 16
        if cur < 0 {
            cur = cur + 65536
            borrow = borrow + 1
        }
        r.d.set(i, cur)
        i = i + 1
    }
    return r
}

# ---------------------------------------------------------------------------
# Wide arithmetic (results are not reduced; used by RSA CRT recombination)
# ---------------------------------------------------------------------------

public def big_add(a: @Big, b: @Big) -> Big {
    n = a.n
    if b.n > n {
        n = b.n
    }
    r = big_new(n + 1)
    carry = 0
    i = 0
    while i < n {
        x = 0
        if i < a.n {
            x = a.d.get(i)
        }
        y = 0
        if i < b.n {
            y = b.d.get(i)
        }
        cur = x + y + carry
        r.d.set(i, cur & 65535)
        carry = cur >> 16
        i = i + 1
    }
    r.d.set(n, carry)
    return r
}

# Schoolbook multiply; the result has 2*max(a.n,b.n) limbs.
public def big_mul(a: @Big, b: @Big) -> Big {
    n = a.n
    if b.n > n {
        n = b.n
    }
    r = big_new(2 * n)
    i = 0
    while i < a.n {
        ai = a.d.get(i)
        carry = 0
        j = 0
        while j < b.n {
            cur = r.d.get(i + j) + ai * b.d.get(j) + carry
            r.d.set(i + j, cur & 65535)
            carry = cur >> 16
            j = j + 1
        }
        k = i + b.n
        while carry > 0 and k < 2 * n {
            cur = r.d.get(k) + carry
            r.d.set(k, cur & 65535)
            carry = cur >> 16
            k = k + 1
        }
        i = i + 1
    }
    return r
}

# a mod m for arbitrary widths, by binary reduction (MSB-first). Used by RSA
# CRT, where the signature representative is wider than p and q.
public def big_mod(a: @Big, m: @Big) -> Big {
    n = m.n
    r = big_new(n)
    bits = big_bit_len(@a)
    i = bits - 1
    while i >= 0 {
        carry = big_bit(@a, i)
        j = 0
        while j < n {
            cur = r.d.get(j) * 2 + carry
            r.d.set(j, cur & 65535)
            carry = cur >> 16
            j = j + 1
        }
        need = carry != 0
        if not need {
            if big_cmp(@r, m) >= 0 {
                need = True
            }
        }
        if need {
            borrow = 0
            j = 0
            while j < n {
                cur = r.d.get(j) - m.d.get(j) - borrow
                if cur < 0 {
                    cur = cur + 65536
                    borrow = 1
                } else {
                    borrow = 0
                }
                r.d.set(j, cur)
                j = j + 1
            }
        }
        i = i - 1
    }
    return r
}

# ---------------------------------------------------------------------------
# Montgomery arithmetic
# ---------------------------------------------------------------------------

public class Mont {
    n: int
    m: Big
    n0: int
    one: Big
    r2: Big
}

def double_mod(a: @Big, m: @Big) -> Big {
    t = add_scratch(@a, @a)
    return reduce_scratch(@t, m)
}

public def mont_new(m: @Big) -> Mont {
    mc = Mont()
    mc.n = m.n
    mc.m = big_copy(@m)
    m0 = m.d.get(0)
    inv = 1
    i = 0
    while i < 5 {
        inv = (inv * (2 - ((m0 * inv) & 65535))) & 65535
        i = i + 1
    }
    mc.n0 = (65536 - inv) & 65535
    r = big_from_int(1, m.n)
    i = 0
    while i < 16 * m.n {
        r = double_mod(@r, m)
        i = i + 1
    }
    mc.one = r
    r2 = big_copy(@r)
    i = 0
    while i < 16 * m.n {
        r2 = double_mod(@r2, m)
        i = i + 1
    }
    mc.r2 = r2
    return mc
}

public def mont_mul(mc: @Mont, a: @Big, b: @Big) -> Big {
    n = mc.n
    size = 2 * n + 2
    t = List[int]()
    i = 0
    while i < size {
        t.push(0)
        i = i + 1
    }
    i = 0
    while i < n {
        ai = a.d.get(i)
        carry = 0
        j = 0
        while j < n {
            cur = t.get(i + j) + ai * b.d.get(j) + carry
            t.set(i + j, cur & 65535)
            carry = cur >> 16
            j = j + 1
        }
        k = i + n
        while carry > 0 and k < size {
            cur = t.get(k) + carry
            t.set(k, cur & 65535)
            carry = cur >> 16
            k = k + 1
        }
        i = i + 1
    }

    i = 0
    while i < n {
        u = (t.get(i) * mc.n0) & 65535
        carry = 0
        j = 0
        while j < n {
            cur = t.get(i + j) + u * mc.m.d.get(j) + carry
            t.set(i + j, cur & 65535)
            carry = cur >> 16
            j = j + 1
        }
        k = i + n
        while carry > 0 and k < size {
            cur = t.get(k) + carry
            t.set(k, cur & 65535)
            carry = cur >> 16
            k = k + 1
        }
        i = i + 1
    }

    # The REDC result occupies t[n..2n] as an (n+1)-limb value.
    r = List[int]()
    i = 0
    while i <= n {
        r.push(t.get(i + n))
        i = i + 1
    }
    mod = mc.m
    reduced = reduce_scratch(@r, @mod)
    return reduced
}

public def mont_from(mc: @Mont, a: @Big) -> Big {
    t = List[int]()
    i = 0
    while i < mc.n {
        t.push(a.d.get(i))
        i = i + 1
    }
    t.push(0)
    mod = mc.m
    small = reduce_scratch(@t, @mod)
    r2 = mc.r2
    return mont_mul(mc, @small, @r2)
}

public def mont_to(mc: @Mont, a: @Big) -> Big {
    one = big_from_int(1, mc.n)
    return mont_mul(mc, a, @one)
}

public def mont_add(mc: @Mont, a: @Big, b: @Big) -> Big {
    t = add_scratch(@a, @b)
    return reduce_scratch(@t, mc.m)
}

public def mont_sub(mc: @Mont, a: @Big, b: @Big) -> Big {
    mod = mc.m
    return big_sub_mod(@a, @b, @mod)
}

public def mont_is_zero(mc: @Mont, a: @Big) -> bool {
    return big_is_zero(@a)
}

public def mont_pow(mc: @Mont, base: @Big, exp: @Big) -> Big {
    one = mc.one
    result = big_copy(@one)
    b = big_copy(@base)
    bits = big_bit_len(@exp)
    i = bits - 1
    while i >= 0 {
        result = mont_mul(mc, @result, @result)
        if big_bit(@exp, i) != 0 {
            result = mont_mul(mc, @result, @b)
        }
        i = i - 1
    }
    return result
}

public def mont_pow_int(mc: @Mont, base: @Big, exp: int) -> Big {
    one = mc.one
    result = big_copy(@one)
    b = big_copy(@base)
    bits = 0
    v = exp
    while v > 0 {
        bits = bits + 1
        v = v >> 1
    }
    i = bits - 1
    while i >= 0 {
        result = mont_mul(mc, @result, @result)
        if (exp >> i) & 1 != 0 {
            result = mont_mul(mc, @result, @b)
        }
        i = i - 1
    }
    return result
}

# Inverse modulo a prime modulus: a^(m-2).
public def mont_inv(mc: @Mont, a: @Big) -> Big {
    mod = mc.m
    e = big_sub_small(@mod, 2)
    return mont_pow(mc, @a, @e)
}
