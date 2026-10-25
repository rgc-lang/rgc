# http2: HPACK static/dynamic tables, Huffman decoding, request/response header encoding, frame-header encoding (no network).
import bytes
import http2

def push_str(b: @var Bytes, s: str) {
    i = 0
    while i < s.len() {
        b.push(s.char_at(i))
        i = i + 1
    }
}

def line(hl: @H2HeaderList, i: int) -> str {
    f = hl.fields.get(i)
    return f.name + "=" + f.value
}

def main() -> int {
    # RFC 7541 C.4.1: Huffman-encoded :authority: www.example.com
    d1 = http2.new_decoder()
    rfc = bytes.bytes_new(17)
    rfc.push(130)
    rfc.push(134)
    rfc.push(132)
    rfc.push(65)
    rfc.push(140)
    rfc.push(241)
    rfc.push(227)
    rfc.push(194)
    rfc.push(229)
    rfc.push(242)
    rfc.push(58)
    rfc.push(107)
    rfc.push(160)
    rfc.push(171)
    rfc.push(144)
    rfc.push(244)
    rfc.push(255)
    h1 = http2.decode_block(d1, rfc, 65536)
    print("rfc", h1.ok, h1.fields.len(), line(h1, 0), line(h1, 3))

    # Request header encoding: pseudo-header order is fixed; connection/host are filtered, custom headers stay.
    d2 = http2.new_decoder()
    hs = List[str]()
    hs.push("user-agent: rgc-test")
    hs.push("connection: keep-alive")
    hs.push("host: evil.example")
    hs.push("x-token: abc")
    blk = http2.encode_request_headers("POST", "https", "example.com:8443", "/a?b=1", hs)
    h2 = http2.decode_block(d2, blk, 65536)
    print("req", h2.ok, h2.fields.len())
    i = 0
    while i < h2.fields.len() {
        print("h", line(h2, i))
        i = i + 1
    }

    # Static table index: 0x82 = :method GET.
    d3 = http2.new_decoder()
    one = bytes.bytes_new(1)
    one.push(130)
    h3 = http2.decode_block(d3, one, 65536)
    print("static", h3.ok, line(h3, 0))

    # Dynamic table: after an incremental-index insertion, index 62 retrieves the newest entry.
    d4 = http2.new_decoder()
    dyn = bytes.bytes_new(24)
    dyn.push(64)
    dyn.push(10)
    push_str(dyn, "custom-key")
    dyn.push(12)
    push_str(dyn, "custom-value")
    h4 = http2.decode_block(d4, dyn, 65536)
    idx = bytes.bytes_new(1)
    idx.push(190)
    h5 = http2.decode_block(d4, idx, 65536)
    print("dyn", h4.ok, h4.fields.len(), h5.ok, line(h5, 0))

    # Response header and trailers encoding.
    rs = List[str]()
    rs.push("content-type: text/plain")
    rb = http2.encode_response_headers(200, rs)
    d5 = http2.new_decoder()
    h6 = http2.decode_block(d5, rb, 65536)
    print("resp", h6.ok, h6.fields.len(), line(h6, 0), line(h6, 1))

    ts = List[str]()
    ts.push("x-trl: yes")
    tb = http2.encode_trailers(ts)
    d6 = http2.new_decoder()
    h7 = http2.decode_block(d6, tb, 65536)
    print("trl", h7.ok, h7.fields.len(), line(h7, 0))

    # Frame header: 24-bit length, type, flags, 31-bit stream ID.
    pl = bytes.bytes_new(3)
    pl.push(1)
    pl.push(2)
    pl.push(3)
    fr = http2.encode_frame(0, 1, 1, pl)
    print("frame", fr.len, fr.get(0), fr.get(1), fr.get(2), fr.get(3),
          fr.get(4), fr.get(8))

    # Truncated strings and header-list limits should both error.
    d7 = http2.new_decoder()
    bad = bytes.bytes_new(4)
    bad.push(0)
    bad.push(10)
    push_str(bad, "abc")
    h8 = http2.decode_block(d7, bad, 65536)
    print("bad", h8.ok, h8.error)

    d8 = http2.new_decoder()
    h9 = http2.decode_block(d8, rb, 4)
    print("limit", h9.ok, h9.error)
    return 0
}
