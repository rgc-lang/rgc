# TLS/HTTPS suite: generate local self-signed certificates and start openssl s_server instances
# constrained to specific cipher suites, groups, certificate types and ALPN, then compile
# tests/tls/main.rg and assert (see the checks below for the covered behavior).
#
# Run by `rgc test tests/tls` — argv[1] is this directory; the compiler under test is in $RGC.
# Prints "SKIP tls (...)" and exits 0 when openssl or the servers are unavailable.

import _testlib
import os

def tls_kill_all(tmp: str) {
    names = List[str]()
    names.push("server")
    names.push("mtls")
    names.push("aes256")
    names.push("chacha")
    names.push("p256")
    names.push("ecdsa")
    names.push("ecdsa_mtls")
    names.push("alpn")
    for n in names {
        _testlib.kill_bg(tmp + "/pid_" + n)
    }
}

# One check: some line of `out` must start with `prefix`.
def tls_chk(out: str, prefix: str, desc: str, path: str, counts: @Counts) {
    if _testlib.out_has_line(out, prefix) {
        return
    }
    print("FAIL tls (" + desc + ")")
    _testlib.show_head(path, 30)
    counts.fails = counts.fails + 1
}

# 'alpn_h2 True <4-digit suite id> h2': the negotiated id varies, its shape does not.
def tls_alpn_ok(out: str) -> bool {
    for ln in out.split("\n") {
        if ln.startswith("alpn_h2 True ") and ln.endswith(" h2") {
            mid = ln.slice(13, ln.len() - 3)
            if mid.len() == 4 {
                if mid.char_at(0) >= 48 and mid.char_at(0) <= 57 and
                        mid.char_at(1) >= 48 and mid.char_at(1) <= 57 and
                        mid.char_at(2) >= 48 and mid.char_at(2) <= 57 and
                        mid.char_at(3) >= 48 and mid.char_at(3) <= 57 {
                    return True
                }
            }
        }
    }
    return False
}

# Start one s_server; returns False (and prints SKIP context) when it never becomes ready.
def tls_start_server(tmp: str, name: str, port: int, args: str) -> bool {
    cmd = "openssl s_server -accept " + to_string(port) + " " + args
    _testlib.bg_start(cmd, tmp + "/" + name + ".log", tmp + "/pid_" + name)
    if _testlib.wait_port(port, 50) {
        return True
    }
    print("SKIP tls (" + name + " s_server not ready)")
    _testlib.show_head(tmp + "/" + name + ".log", 5)
    return False
}

def tls_run(tmp: str, suite_dir: str) -> int {
    cert = tmp + "/cert.pem"
    key = tmp + "/key.pem"
    ec_cert = tmp + "/ec-cert.pem"
    ec_key = tmp + "/ec-key.pem"

    rc = _testlib.run_rc(
        "openssl req -x509 -newkey rsa:2048 -nodes -keyout " + _testlib.q(key) +
            " -out " + _testlib.q(cert) + " -days 1 -subj /CN=localhost" +
            " -addext subjectAltName=DNS:localhost > " + _testlib.q(tmp + "/gen.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP tls (failed to generate test certificate)")
        _testlib.show_head(tmp + "/gen.log", 5)
        return 0
    }
    rc = _testlib.run_rc(
        "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes" +
            " -keyout " + _testlib.q(ec_key) + " -out " + _testlib.q(ec_cert) + " -days 1" +
            " -subj /CN=localhost -addext subjectAltName=DNS:localhost > " +
            _testlib.q(tmp + "/gen-ec.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP tls (failed to generate ECDSA test certificate)")
        _testlib.show_head(tmp + "/gen-ec.log", 5)
        return 0
    }

    port = _testlib.free_port()
    mtls_port = _testlib.free_port()
    aes256_port = _testlib.free_port()
    chacha_port = _testlib.free_port()
    p256_port = _testlib.free_port()
    ecdsa_port = _testlib.free_port()
    ecdsa_mtls_port = _testlib.free_port()
    alpn_port = _testlib.free_port()

    rsa_args = "-cert " + _testlib.q(cert) + " -key " + _testlib.q(key)
    ec_args = "-cert " + _testlib.q(ec_cert) + " -key " + _testlib.q(ec_key)

    ok = True
    if not tls_start_server(tmp, "server", port, rsa_args + " -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "mtls", mtls_port, rsa_args + " -Verify 1 -CAfile " + _testlib.q(cert) + " -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "aes256", aes256_port, rsa_args + " -ciphersuites TLS_AES_256_GCM_SHA384 -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "chacha", chacha_port, rsa_args + " -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "p256", p256_port, rsa_args + " -groups P-256 -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "ecdsa", ecdsa_port, ec_args + " -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "alpn", alpn_port, rsa_args + " -alpn h2 -www") {
        ok = False
    }
    if ok and not tls_start_server(tmp, "ecdsa_mtls", ecdsa_mtls_port, ec_args + " -Verify 1 -CAfile " + _testlib.q(ec_cert) + " -www") {
        ok = False
    }
    if not ok {
        tls_kill_all(tmp)
        return 0
    }

    rgc = _testlib.rgc()
    bin_path = tmp + "/tls_test"
    rc = _testlib.run_rc(
        _testlib.q(rgc) + " " + _testlib.q(suite_dir + "/main.rg") + " -o " + _testlib.q(bin_path) +
            " > " + _testlib.q(tmp + "/build.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL tls (compile)")
        _testlib.show_head(tmp + "/build.log", 20)
        tls_kill_all(tmp)
        return 1
    }

    counts = _testlib.new_counts()

    os.setenv("SSL_CERT_FILE", cert)
    ok_out_path = tmp + "/ok.out"
    rc = _testlib.run_rc(
        _testlib.q(bin_path) +
            " --port " + to_string(port) +
            " --mtls-port " + to_string(mtls_port) +
            " --aes256-port " + to_string(aes256_port) +
            " --chacha-port " + to_string(chacha_port) +
            " --p256-port " + to_string(p256_port) +
            " --ecdsa-port " + to_string(ecdsa_port) +
            " --ecdsa-mtls-port " + to_string(ecdsa_mtls_port) +
            " --alpn-port " + to_string(alpn_port) +
            " --cert " + _testlib.q(cert) + " --key " + _testlib.q(key) +
            " --ecdsa-cert " + _testlib.q(ec_cert) + " --ecdsa-key " + _testlib.q(ec_key) +
            " > " + _testlib.q(ok_out_path) + " 2>&1",
        tmp + "/rc")
    out = _testlib.readf(ok_out_path)
    tls_chk(out, "http_verify True", "http.get did not pass https certificate verification", ok_out_path, @var counts)
    tls_chk(out, "status 200", "response status is not 200", ok_out_path, @var counts)
    tls_chk(out, "ctype text/html", "Content-Type parse error", ok_out_path, @var counts)
    tls_chk(out, "body_nonempty True", "response body is empty", ok_out_path, @var counts)
    tls_chk(out, "https_verify True", "https.get verification connection failed", ok_out_path, @var counts)
    tls_chk(out, "insecure True", "get_insecure failed", ok_out_path, @var counts)
    tls_chk(out, "tls_connect True", "tls.connect failed", ok_out_path, @var counts)
    tls_chk(out, "tls_ok_line True", "TLS direct connection did not receive an HTTP status line", ok_out_path, @var counts)
    tls_chk(out, "mtls_tls True", "client certificate handshake failed", ok_out_path, @var counts)
    tls_chk(out, "mtls_http True", "HttpClient client-certificate request failed", ok_out_path, @var counts)
    tls_chk(out, "mtls_status 200", "mTLS response status is not 200", ok_out_path, @var counts)
    tls_chk(out, "mtls_required False", "handshake succeeded without a client certificate", ok_out_path, @var counts)
    tls_chk(out, "mtls_bad_cert False cannot load client certificate", "missing certificate-file error message", ok_out_path, @var counts)
    tls_chk(out, "aes256 True 4866", "AES-256-GCM-SHA384 was not negotiated", ok_out_path, @var counts)
    tls_chk(out, "aes256_http True", "AES-256-GCM-SHA384 data transfer failed", ok_out_path, @var counts)
    tls_chk(out, "chacha True 4867", "ChaCha20-Poly1305 was not negotiated", ok_out_path, @var counts)
    tls_chk(out, "chacha_http True", "ChaCha20-Poly1305 data transfer failed", ok_out_path, @var counts)
    tls_chk(out, "p256 True", "P-256 key share handshake failed", ok_out_path, @var counts)
    tls_chk(out, "p256_http True", "P-256 data transfer failed", ok_out_path, @var counts)
    tls_chk(out, "ecdsa True", "ECDSA server certificate handshake failed", ok_out_path, @var counts)
    tls_chk(out, "ecdsa_http True", "ECDSA server certificate data transfer failed", ok_out_path, @var counts)
    if not tls_alpn_ok(out) {
        print("FAIL tls (ALPN h2 was not negotiated)")
        _testlib.show_head(ok_out_path, 30)
        counts.fails = counts.fails + 1
    }
    tls_chk(out, "alpn_h2_http True", "ALPN h2 data transfer failed", ok_out_path, @var counts)
    tls_chk(out, "ecdsa_mtls True", "ECDSA client certificate handshake failed", ok_out_path, @var counts)
    tls_chk(out, "ecdsa_mtls_http True", "ECDSA mTLS data transfer failed", ok_out_path, @var counts)
    tls_chk(out, "hostname_mismatch False certificate hostname mismatch for 127.0.0.1", "hostname mismatch was not rejected", ok_out_path, @var counts)
    tls_chk(out, "refused False", "connecting to port 1 should fail", ok_out_path, @var counts)
    tls_chk(out, "not_https False not an https URL", "non-https URL was not rejected", ok_out_path, @var counts)

    noverify_path = tmp + "/noverify.out"
    rc = _testlib.run_rc(
        "env -u SSL_CERT_FILE -u SSL_CERT_DIR " + _testlib.q(bin_path) +
            " --port " + to_string(port) + " > " + _testlib.q(noverify_path) + " 2>&1",
        tmp + "/rc")
    nv = _testlib.readf(noverify_path)
    tls_chk(nv, "http_verify False", "self-signed certificate should fail verification without the test CA", noverify_path, @var counts)
    if not _testlib.out_has_line_with(nv, "http_verify_error ", "certificate") {
        print("FAIL tls (missing certificate verification error message)")
        _testlib.show_head(noverify_path, 30)
        counts.fails = counts.fails + 1
    }
    tls_chk(nv, "https_verify False", "https.get should fail verification without a CA", noverify_path, @var counts)
    tls_chk(nv, "insecure True", "get_insecure failed without a certificate", noverify_path, @var counts)

    tls_kill_all(tmp)
    if counts.fails > 0 {
        return 1
    }
    print("PASS tls (cert verification + insecure + mTLS RSA/ECDSA + AES-256/ChaCha20/P-256/ECDSA/ALPN/hostname)")
    return 0
}

def main() -> int {
    suite_dir = args().get(1)
    if not _testlib.have_tool("openssl") {
        print("SKIP tls (openssl unavailable)")
        return 0
    }
    tmp = _testlib.mktmpd("tls")
    if tmp.len() == 0 {
        print("FAIL tls (cannot create scratch directory)")
        return 1
    }
    rc = tls_run(tmp, suite_dir)
    system("rm -rf " + _testlib.q(tmp))
    return rc
}
