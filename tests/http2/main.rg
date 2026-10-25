# HTTP/2 end-to-end test: tests/run_http2.sh starts a local nghttpd, then this runs.
# Arguments: --port <local TLS port> [--ca <server certificate PEM>]
# Covers: low-level frames/flow control/trailers/large send-receive, plus HttpClient's automatic ALPN integration.
import bytes
import http
import http2

def hdrs() -> List[str] {
    hs = List[str]()
    hs.push("user-agent: rgc-h2-test")
    hs.push("accept: */*")
    return hs
}

def main() -> int {
    argv = args()
    port = 0
    ca = ""
    i = 1
    while i + 1 < argv.len() {
        k = argv.get(i)
        v = argv.get(i + 1)
        if k == "--port" {
            port = v.to_int().unwrap()
        } elif k == "--ca" {
            ca = v
        }
        i = i + 2
    }
    if port == 0 {
        print("usage: http2_test --port PORT [--ca PEM]")
        return 1
    }
    authority = "localhost:" + to_string(port)
    base = "https://" + authority

    # ---- low-level http2 API ----
    cr = http2.connect("localhost", port, 5000, False, "", "", "")
    print("h2_connect", cr.ok)
    if not cr.ok {
        print("h2_connect_error", cr.error)
        return 1
    }
    c = cr.conn
    print("h2_alpn", c.tls.get_alpn())

    r1 = http2.request(c, "GET", "https", authority, "/index.html", hdrs(),
                       "", 0, False, 65536, 33554432)
    t1 = r1.body.to_str()
    print("h2_get", r1.ok, r1.status, r1.body.len, t1.slice(0, 5))
    print("h2_trailers", r1.trailers.len(), r1.trailers.get(0))

    r2 = http2.request(c, "GET", "https", authority, "/big.bin", hdrs(),
                       "", 0, False, 65536, 33554432)
    print("h2_big", r2.ok, r2.status, r2.body.len)

    body = bytes.bytes_new(5000)
    i = 0
    while i < 5000 {
        body.push(97 + (i % 26))
        i = i + 1
    }
    r3 = http2.request(c, "POST", "https", authority, "/echo", hdrs(),
                       body.data, body.len, True, 65536, 33554432)
    print("h2_post", r3.ok, r3.status, r3.body.len)

    # ---- concurrent multiplexing (server -m 2; 4 requests must queue) ----
    paths = List[str]()
    paths.push("/index.html")
    paths.push("/sub/index.html")
    paths.push("/big.bin")
    paths.push("/missing.txt")
    mr = http2.get_many(c, "https", authority, paths, hdrs(), 65536, 33554432)
    print("h2_many", mr.ok, mr.responses.len())
    m0 = mr.responses.get(0)
    m1 = mr.responses.get(1)
    m2 = mr.responses.get(2)
    m3 = mr.responses.get(3)
    t0 = m0.body.to_str()
    t1 = m1.body.to_str()
    print("h2_many_0", m0.ok, m0.status, m0.body.len, t0.slice(0, 5))
    print("h2_many_1", m1.ok, m1.status, m1.body.len, t1.slice(0, 7))
    print("h2_many_2", m2.ok, m2.status, m2.body.len)
    print("h2_many_3", m3.ok, m3.status)
    print("h2_many_trailer", m0.trailers.len(), m0.trailers.get(0))

    empty_paths = List[str]()
    me = http2.get_many(c, "https", authority, empty_paths, hdrs(), 65536, 33554432)
    print("h2_many_empty", me.ok, me.responses.len())

    # A single stream over the limit is cancelled; the other stream is unaffected
    lim_paths = List[str]()
    lim_paths.push("/big.bin")
    lim_paths.push("/index.html")
    ml = http2.get_many(c, "https", authority, lim_paths, hdrs(), 65536, 1000)
    l0 = ml.responses.get(0)
    l1 = ml.responses.get(1)
    print("h2_many_limit", ml.ok, l0.ok, l0.error, l1.ok, l1.status, l1.body.len)

    # The same connection can still serve sequential requests after multiplexing
    r4 = http2.request(c, "GET", "https", authority, "/index.html", hdrs(),
                       "", 0, False, 65536, 33554432)
    print("h2_after_many", r4.ok, r4.status, r4.body.len)
    c.close()

    # ---- HttpClient automatic negotiation (no CA given: test without verification first) ----
    hc = http.new_client()
    hc.verify_tls = False
    g = hc.get(base + "/index.html")
    gr = g.response
    print("cli_get", g.ok, gr.status, gr.version, gr.body.slice(0, 5))
    print("cli_trailer", http.trailer(@gr, "x-trl"))
    srv = http.header(@gr, "server")
    print("cli_server", srv.len() > 0)

    gb = hc.get(base + "/big.bin")
    print("cli_big", gb.ok, gb.response.body_bytes.len)

    gp = hc.post(base + "/echo", "hello-h2")
    print("cli_post", gp.ok, gp.response.status, gp.response.body)

    gs = hc.get(base + "/sub")
    print("cli_redirect", gs.ok, gs.response.status, gs.response.body.slice(0, 7))

    gm = hc.get(base + "/missing.txt")
    print("cli_404", gm.ok, gm.response.status)
    hc.close()

    # ---- certificate verification (CA + SAN) ----
    hv = http.new_client()
    if ca.len() > 0 {
        hv.set_ca_file(ca)
    }
    gv = hv.get(base + "/index.html")
    print("cli_verify", gv.ok, gv.response.version)
    hv.close()

    # ---- response-body limits ----
    hl = http.new_client()
    hl.verify_tls = False
    hl.max_body = 1000
    gl = hl.get(base + "/big.bin")
    print("cli_limit", gl.ok, gl.error)
    hl.close()
    return 0
}
