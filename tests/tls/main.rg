# TLS/HTTPS client test: tests/run_tls.sh starts a local openssl s_server, then this runs.
# Arguments: --port <local TLS port>; certificate verification depends on the SSL_CERT_FILE environment variable.
import http
import https
import tls

# Connect with verification and a one-shot HTTP/1.0 request; prints the negotiated
# cipher suite and ALPN result so the runner can assert cipher/group coverage.
def probe(name: str, host: str, port: int, ca: str, offer_h2: bool) -> int {
    if port == 0 {
        return 0
    }
    c = tls.connect_alpn(host, port, 10000, True, ca, "", "", offer_h2)
    if not c.ok {
        print(name, False, c.error)
        return 1
    }
    s = c.conn
    print(name, True, s.suite, s.get_alpn())
    s.send("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
    raw = ""
    while True {
        r = s.recv(4096)
        if not r.ok or r.value.len() == 0 {
            break
        }
        raw = raw + r.value
    }
    print(name + "_http", raw.contains("200"))
    s.close()
    return 0
}

def main() -> int {
    argv = args()
    port = 0
    mtls_port = 0
    aes256_port = 0
    chacha_port = 0
    p256_port = 0
    ecdsa_port = 0
    ecdsa_mtls_port = 0
    alpn_port = 0
    cert = ""
    key = ""
    ecdsa_cert = ""
    ecdsa_key = ""
    i = 1
    while i + 1 < argv.len() {
        k = argv.get(i)
        v = argv.get(i + 1)
        if k == "--port" {
            port = v.to_int().unwrap()
        } elif k == "--mtls-port" {
            mtls_port = v.to_int().unwrap()
        } elif k == "--aes256-port" {
            aes256_port = v.to_int().unwrap()
        } elif k == "--chacha-port" {
            chacha_port = v.to_int().unwrap()
        } elif k == "--p256-port" {
            p256_port = v.to_int().unwrap()
        } elif k == "--ecdsa-port" {
            ecdsa_port = v.to_int().unwrap()
        } elif k == "--ecdsa-mtls-port" {
            ecdsa_mtls_port = v.to_int().unwrap()
        } elif k == "--alpn-port" {
            alpn_port = v.to_int().unwrap()
        } elif k == "--cert" {
            cert = v
        } elif k == "--key" {
            key = v
        } elif k == "--ecdsa-cert" {
            ecdsa_cert = v
        } elif k == "--ecdsa-key" {
            ecdsa_key = v
        }
        i = i + 2
    }
    if port == 0 {
        print("usage: tls_test --port PORT [--mtls-port PORT --cert PEM --key PEM]")
        return 1
    }
    base = "https://localhost:" + to_string(port)

    # The http module natively supports https and verifies certificates by default.
    rh = http.get(base + "/")
    print("http_verify", rh.ok)
    if rh.ok {
        res = rh.response
        print("status", res.status)
        print("ctype", http.header(@res, "Content-Type"))
        print("body_nonempty", res.body.len() > 0)
    } else {
        print("http_verify_error", rh.error)
    }

    # Compatibility layer: no certificate verification.
    ri = https.get_insecure(base + "/")
    print("insecure", ri.ok)
    if not ri.ok {
        print("insecure_error", ri.error)
    }

    # Compatibility layer: verifies the certificate. Should succeed when SSL_CERT_FILE points at the test certificate, otherwise fail.
    rv = https.get(base + "/")
    print("https_verify", rv.ok)
    if not rv.ok {
        print("https_verify_error", rv.error)
    }

    # Low-level tls direct connection (verify=False).
    c = tls.connect("localhost", port, 10000, False)
    print("tls_connect", c.ok)
    if c.ok {
        s = c.conn
        s.send("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        raw = ""
        while True {
            r = s.recv(4096)
            if not r.ok {
                print("tls_recv_error", r.error)
                break
            }
            if r.value.len() == 0 {
                break
            }
            raw = raw + r.value
        }
        print("tls_ok_line", raw.contains("200"))
        s.close()
    }

    # Client certificate (mTLS): the server requires and verifies a client certificate.
    if mtls_port > 0 {
        m = tls.connect_mtls("localhost", mtls_port, 10000, True, "", cert, key)
        print("mtls_tls", m.ok)
        if m.ok {
            m.conn.close()
        } else {
            print("mtls_tls_error", m.error)
        }

        hc = http.new_client()
        hc.verify_tls = True
        hc.keep_alive = False
        hc.set_client_cert(cert, key)
        mr = hc.get("https://localhost:" + to_string(mtls_port) + "/")
        print("mtls_http", mr.ok)
        if mr.ok {
            print("mtls_status", mr.response.status)
        } else {
            print("mtls_http_error", mr.error)
        }
        hc.close()

        # Handshake without a client certificate must fail.
        nk = https.get_insecure("https://localhost:" + to_string(mtls_port) + "/")
        print("mtls_required", nk.ok)

        # An unreadable certificate file must give a clear error.
        badc = tls.connect_mtls("localhost", mtls_port, 10000, False, "",
                                "/nonexistent-client-cert.pem", "")
        print("mtls_bad_cert", badc.ok, badc.error)
    }

    # Cipher suites, groups and certificate types (each server is constrained by the runner).
    probe("aes256", "localhost", aes256_port, cert, False)
    probe("chacha", "localhost", chacha_port, cert, False)
    probe("p256", "localhost", p256_port, cert, False)
    probe("ecdsa", "localhost", ecdsa_port, ecdsa_cert, False)
    probe("alpn_h2", "localhost", alpn_port, cert, True)

    # mTLS with an ECDSA client certificate (ECDSA chain and ECDSA CertificateVerify).
    if ecdsa_mtls_port > 0 {
        em = tls.connect_mtls("localhost", ecdsa_mtls_port, 10000, True,
                              ecdsa_cert, ecdsa_cert, ecdsa_key)
        print("ecdsa_mtls", em.ok)
        if em.ok {
            em.conn.send("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
            eraw = ""
            while True {
                er = em.conn.recv(4096)
                if not er.ok or er.value.len() == 0 {
                    break
                }
                eraw = eraw + er.value
            }
            print("ecdsa_mtls_http", eraw.contains("200"))
            em.conn.close()
        } else {
            print("ecdsa_mtls_error", em.error)
        }
    }

    # Hostname verification: the certificate only covers DNS:localhost.
    hm = tls.connect_with_ca("127.0.0.1", port, 10000, True, cert)
    print("hostname_mismatch", hm.ok, hm.error)
    if hm.ok {
        hm.conn.close()
    }

    # Port error paths.
    bad = https.get_insecure("https://localhost:1/")
    print("refused", bad.ok)
    bad_url = https.get_insecure("http://localhost:" + to_string(port) + "/")
    print("not_https", bad_url.ok, bad_url.error)
    return 0
}
