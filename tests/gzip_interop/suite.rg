# gzip interop suite (pure RGC): decode externally-produced and hand-crafted DEFLATE streams,
# then cross-verify RGC-produced streams with the system gzip/gunzip reference implementation.
#
# Covers gzip FEXTRA/FNAME/FCOMMENT/FHCRC headers, stored/dynamic blocks, multi-member gzip,
# zlib and raw-deflate wrappers, trailing garbage, checksum failures, FDICT, corrupted FHCRC
# and reserved header flags.
#
# Run by `rgc test tests/gzip_interop`. The system `gzip` CLI acts as the external counterpart
# (its streams feed the decoder; gunzip re-decodes RGC output) — SKIP when it is unavailable.

import _testlib
import bytes
import gzip

# ---- byte/number helpers ---------------------------------------------------

def put_le16(b: @var Bytes, v: int) {
    b.push(v & 255)
    b.push((v >> 8) & 255)
}

def put_le32(b: @var Bytes, v: int) {
    b.push(v & 255)
    b.push((v >> 8) & 255)
    b.push((v >> 16) & 255)
    b.push((v >> 24) & 255)
}

def put_be32(b: @var Bytes, v: int) {
    b.push((v >> 24) & 255)
    b.push((v >> 16) & 255)
    b.push((v >> 8) & 255)
    b.push(v & 255)
}

def crc32(data: @Bytes) -> int {
    crc = 4294967295
    i = 0
    while i < data.len {
        crc = crc ^ data.get(i)
        k = 0
        while k < 8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 3988292384
            } else {
                crc = crc >> 1
            }
            k = k + 1
        }
        i = i + 1
    }
    return (crc ^ 4294967295) & 4294967295
}

def adler32(data: @Bytes) -> int {
    a = 1
    b = 0
    i = 0
    while i < data.len {
        a = (a + data.get(i)) % 65521
        b = (b + a) % 65521
        i = i + 1
    }
    return ((b << 16) | a) & 4294967295
}

def hash_bytes(data: @Bytes) -> int {
    h = 0
    i = 0
    while i < data.len {
        h = (h * 131 + data.get(i)) % 1000000007
        i = i + 1
    }
    return h
}

def copy_flip(data: @Bytes, idx: int, mask: int) -> Bytes {
    out = bytes.bytes_new(data.len)
    i = 0
    while i < data.len {
        v = data.get(i)
        if i == idx {
            v = v ^ mask
        }
        out.push(v)
        i = i + 1
    }
    return out
}

# ---- payloads ---------------------------------------------------------------

def pay_a() -> Bytes {
    # "hello gzip interop\n" * 3
    unit = bytes.bytes_from_str("hello gzip interop\n")
    out = bytes.bytes_new(54)
    k = 0
    while k < 3 {
        i = 0
        while i < unit.len {
            out.push(unit.get(i))
            i = i + 1
        }
        k = k + 1
    }
    return out
}

def pay_b() -> Bytes {
    out = bytes.bytes_new(300)
    i = 0
    while i < 300 {
        out.push((i * 37 + i / 5) % 256)
        i = i + 1
    }
    return out
}

def pay_c() -> Bytes {
    out = bytes.bytes_new(12000)
    i = 0
    while i < 12000 {
        m = i % 700
        if m < 300 {
            out.push(65 + (i / 700) % 4)
        } elif m < 500 {
            out.push(97 + (i * 13) % 26)
        } else {
            out.push((i * 29 + (i / 700) * 7) % 256)
        }
        i = i + 1
    }
    return out
}

# gzip with FEXTRA + FNAME + FCOMMENT + FHCRC around a level-9 raw-deflate body;
# bad_fhcrc corrupts the header CRC, reserved sets the reserved FLG bit.
def gz_manual(data: @Bytes, body: @Bytes, bad_fhcrc: bool, reserved: bool) -> Bytes {
    hdr = bytes.bytes_new(64)
    hdr.push(31)
    hdr.push(139)
    hdr.push(8)
    flg = 4 | 8 | 16 | 2
    if reserved {
        flg = flg | 32
    }
    hdr.push(flg)
    put_le32(@var hdr, 0)
    hdr.push(2)
    hdr.push(255)
    extra = bytes.bytes_from_str("RGCEXTRA")
    put_le16(@var hdr, extra.len)
    i = 0
    while i < extra.len {
        hdr.push(extra.get(i))
        i = i + 1
    }
    fname = bytes.bytes_from_str("payload.bin")
    i = 0
    while i < fname.len {
        hdr.push(fname.get(i))
        i = i + 1
    }
    hdr.push(0)
    comment = bytes.bytes_from_str("rgc gzip interop")
    i = 0
    while i < comment.len {
        hdr.push(comment.get(i))
        i = i + 1
    }
    hdr.push(0)
    hcrc = crc32(@hdr) & 65535
    if bad_fhcrc {
        hcrc = hcrc ^ 65535
    }
    put_le16(@var hdr, hcrc)
    out = bytes.bytes_new(hdr.len + body.len + 8)
    i = 0
    while i < hdr.len {
        out.push(hdr.get(i))
        i = i + 1
    }
    i = 0
    while i < body.len {
        out.push(body.get(i))
        i = i + 1
    }
    put_le32(@var out, crc32(@data))
    put_le32(@var out, data.len & 4294967295)
    return out
}

# zlib wrapper: 0x78 <flg> + raw-deflate body + big-endian adler32.
def zlib_wrap(data: @Bytes, body: @Bytes, fdict: bool) -> Bytes {
    flg = 0
    if fdict {
        flg = 32
    }
    flg = flg + (31 - (((120 << 8) | flg) % 31)) % 31
    out = bytes.bytes_new(body.len + 8)
    out.push(120)
    out.push(flg)
    if fdict {
        put_be32(@var out, 1)
    }
    i = 0
    while i < body.len {
        out.push(body.get(i))
        i = i + 1
    }
    put_be32(@var out, adler32(@data))
    return out
}

# ---- suite state ------------------------------------------------------------

def gz_fail(name: str, detail: str, counts: @Counts) {
    print("FAIL gzip_interop " + name + " (" + detail + ")")
    counts.fails = counts.fails + 1
}

# Produce a gzip stream of `data` with the system gzip CLI at the given level.
def gz_cli(tmp: str, data: @Bytes, tag: str, level: int) -> Bytes {
    src = tmp + "/" + tag + ".bin"
    dst = tmp + "/" + tag + ".gz"
    w = bytes.write_bytes(src, @data)
    if not w.ok {
        return bytes.bytes_new(0)
    }
    system("gzip -n -" + to_string(level) + " -c " + _testlib.q(src) + " > " + _testlib.q(dst))
    r = bytes.read_bytes(dst)
    if r.ok {
        return r.data
    }
    return bytes.bytes_new(0)
}

# A single final stored deflate block: 01 LEN NLEN data (the level-0 encoding).
def stored_body(data: @Bytes) -> Bytes {
    out = bytes.bytes_new(data.len + 5)
    out.push(1)
    put_le16(@var out, data.len)
    put_le16(@var out, data.len ^ 65535)
    i = 0
    while i < data.len {
        out.push(data.get(i))
        i = i + 1
    }
    return out
}

# A complete gzip stream around a given raw-deflate body.
def gz_wrap(data: @Bytes, body: @Bytes) -> Bytes {
    out = bytes.bytes_new(body.len + 18)
    out.push(31)
    out.push(139)
    out.push(8)
    out.push(0)
    put_le32(@var out, 0)
    out.push(0)
    out.push(255)
    i = 0
    while i < body.len {
        out.push(body.get(i))
        i = i + 1
    }
    put_le32(@var out, crc32(@data))
    put_le32(@var out, data.len & 4294967295)
    return out
}

# Raw-deflate body of a CLI-produced stream (10-byte header, 8-byte trailer).
def raw_body(stream: @Bytes) -> Bytes {
    return stream.slice(10, stream.len - 8)
}

def expect_ok(name: str, stream: @Bytes, want: @Bytes, members: int, counts: @Counts) {
    r = gzip.decompress(@stream)
    if not r.ok {
        gz_fail(name, "decode failed: " + r.error, @var counts)
        return
    }
    d = r.data
    if hash_bytes(@d) != hash_bytes(@want) or d.len != want.len {
        gz_fail(name, "payload mismatch", @var counts)
        return
    }
    if r.members != members {
        gz_fail(name, "members=" + to_string(r.members) + " want " + to_string(members), @var counts)
        return
    }
}

def expect_err(name: str, stream: @Bytes, want_err: str, counts: @Counts) {
    r = gzip.decompress(@stream)
    if r.ok {
        gz_fail(name, "decode should have failed", @var counts)
        return
    }
    if not r.error.contains(want_err) {
        gz_fail(name, "error '" + r.error + "' want '" + want_err + "'", @var counts)
        return
    }
}

def main() -> int {
    if not _testlib.have_tool("gzip") {
        print("SKIP gzip_interop (gzip unavailable)")
        return 0
    }
    tmp = _testlib.mktmpd("gz")
    if tmp.len() == 0 {
        print("FAIL gzip_interop (cannot create scratch directory)")
        return 1
    }
    counts = _testlib.new_counts()

    a = pay_a()
    b = pay_b()
    c = pay_c()
    a5 = a.slice(0, 5)

    # Streams produced by the system gzip CLI (external provenance).
    gz_c9 = gz_cli(tmp, @c, "c9", 9)
    gz_a0 = gz_cli(tmp, @a, "a0", 1)
    gz_b9 = gz_cli(tmp, @b, "b9", 9)
    gz_a1 = gz_cli(tmp, @a, "a1", 1)
    gz_a9 = gz_cli(tmp, @a, "a9", 9)
    gz_a5 = gz_cli(tmp, @a5, "a5", 1)
    if gz_c9.len == 0 or gz_a0.len == 0 or gz_b9.len == 0 or gz_a1.len == 0 or gz_a9.len == 0 or gz_a5.len == 0 {
        print("FAIL gzip_interop (system gzip produced no stream)")
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    body_c9 = raw_body(@gz_c9)
    body_c0 = stored_body(@c)
    gz_c0 = gz_wrap(@c, @body_c0)

    # Hand-crafted fixtures around externally-produced deflate bodies.
    multi = bytes.bytes_concat(@gz_a0, @gz_b9)
    multi = bytes.bytes_concat(@multi, @gz_a5)
    trailing = bytes.bytes_concat(@gz_a9, bytes.bytes_from_str("trailing-garbage"))
    gz_fname = gz_manual(@c, @body_c9, False, False)
    zl_mixed = zlib_wrap(@c, @body_c9, False)
    zl_stored = zlib_wrap(@c, @body_c0, False)
    zl_dict = zlib_wrap(@a, raw_body(@gz_a9), True)
    zl_bad_adler = zlib_wrap(@a, raw_body(@gz_a9), False)
    bad_adler_len = zl_bad_adler.len
    zl_bad_adler = copy_flip(@zl_bad_adler, bad_adler_len - 1, 255)
    bad_crc_len = gz_a9.len
    bad_crc = copy_flip(@gz_a9, bad_crc_len - 8, 255)
    missing_trailer = gz_c9.slice(0, gz_c9.len - 8)
    gz_bad_fhcrc = gz_manual(@a, raw_body(@gz_a9), True, False)
    gz_reserved = gz_manual(@a, raw_body(@gz_a9), False, True)

    # Decode checks.
    expect_ok("gz_fname", @gz_fname, @c, 1, @var counts)
    expect_ok("gz_stored", @gz_c0, @c, 1, @var counts)
    expect_ok("gz_multi", @multi, bytes.bytes_concat(bytes.bytes_concat(@a, @b), @a5), 3, @var counts)
    expect_ok("zl_mixed", @zl_mixed, @c, 1, @var counts)
    expect_ok("zl_stored", @zl_stored, @c, 1, @var counts)
    expect_ok("raw_mixed", @body_c9, @c, 1, @var counts)
    expect_ok("raw_stored", @body_c0, @c, 1, @var counts)
    expect_ok("gz_trailing", @trailing, @a, 1, @var counts)
    expect_err("bad_crc", @bad_crc, "incorrect data check", @var counts)
    expect_err("zl_bad_adler", @zl_bad_adler, "incorrect data check", @var counts)
    expect_err("missing_trailer", @missing_trailer, "truncated compressed data", @var counts)
    expect_err("zl_dict", @zl_dict, "preset dictionary not supported", @var counts)
    expect_err("gz_bad_fhcrc", @gz_bad_fhcrc, "header crc mismatch", @var counts)
    expect_err("gz_reserved", @gz_reserved, "unknown header flags set", @var counts)

    # Encode checks: RGC round-trip plus gunzip re-decoding every stream.
    comp_names = List[str]()
    comp_levels = List[int]()
    comp_names.push("a")
    comp_levels.push(0)
    comp_names.push("a")
    comp_levels.push(1)
    comp_names.push("a")
    comp_levels.push(6)
    comp_names.push("a")
    comp_levels.push(9)
    comp_names.push("b")
    comp_levels.push(0)
    comp_names.push("b")
    comp_levels.push(6)
    comp_names.push("b")
    comp_levels.push(9)
    comp_names.push("c")
    comp_levels.push(0)
    comp_names.push("c")
    comp_levels.push(9)

    i = 0
    external_checked = 0
    while i < comp_names.len() {
        name = comp_names.get(i)
        level = comp_levels.get(i)
        payload = a
        if _testlib.str_eq(name, "b") {
            payload = b
        }
        if _testlib.str_eq(name, "c") {
            payload = c
        }
        r = gzip.compress_level(@payload, level)
        if not r.ok {
            gz_fail("comp_" + name + to_string(level), "compress failed: " + r.error, @var counts)
            i = i + 1
            continue
        }
        rd = r.data
        rt = gzip.decompress(@rd)
        rtd = rt.data
        if not rt.ok or rtd.len != payload.len or hash_bytes(@rtd) != hash_bytes(@payload) {
            gz_fail("comp_" + name + to_string(level), "round-trip mismatch", @var counts)
            i = i + 1
            continue
        }
        # gunzip must decode the RGC stream back to the exact payload.
        stream_path = tmp + "/comp_" + name + to_string(level) + ".gz"
        out_path = tmp + "/comp_" + name + to_string(level) + ".out"
        w = bytes.write_bytes(stream_path, @rd)
        if not w.ok {
            gz_fail("comp_" + name + to_string(level), "cannot write stream", @var counts)
            i = i + 1
            continue
        }
        rc = _testlib.run_rc(
            "gzip -dc " + _testlib.q(stream_path) + " > " + _testlib.q(out_path) + " 2>" +
                _testlib.q(tmp + "/gunzip.err"),
            tmp + "/rc")
        if rc != 0 {
            gz_fail("comp_" + name + to_string(level), "gunzip rejected the stream", @var counts)
            i = i + 1
            continue
        }
        back = bytes.read_bytes(out_path)
        bd = back.data
        if not back.ok or back.size != payload.len or hash_bytes(@bd) != hash_bytes(@payload) {
            gz_fail("comp_" + name + to_string(level), "gunzip payload mismatch", @var counts)
            i = i + 1
            continue
        }
        external_checked = external_checked + 1
        i = i + 1
    }

    system("rm -rf " + _testlib.q(tmp))
    if counts.fails > 0 {
        return 1
    }
    print("PASS gzip_interop (headers/blocks/multi-member/zlib/raw + " +
        to_string(external_checked) + " streams re-decoded by gunzip)")
    return 0
}
