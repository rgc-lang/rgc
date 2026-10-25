# HTTP/2 end-to-end suite: generate a local self-signed certificate, start nghttpd (TLS + ALPN h2)
# and run tests/http2/main.rg against it, comparing the full output with tests/http2/expected.
# Covers: preface/SETTINGS/HEADERS/DATA/flow control/trailers/large send-receive/concurrent
# multiplexing, and HttpClient's automatic ALPN integration.
#
# Run by `rgc test tests/http2` — argv[1] is this directory; the compiler under test is in $RGC.

import _testlib

def h2_run(tmp: str, suite_dir: str) -> int {
    key = tmp + "/key.pem"
    cert = tmp + "/cert.pem"
    rc = _testlib.run_rc(
        "openssl req -x509 -newkey rsa:2048 -nodes -keyout " + _testlib.q(key) +
            " -out " + _testlib.q(cert) + " -days 1 -subj /CN=localhost" +
            " -addext subjectAltName=DNS:localhost > " + _testlib.q(tmp + "/gen.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP http2 (failed to generate test certificate)")
        _testlib.show_head(tmp + "/gen.log", 5)
        return 0
    }

    root = tmp + "/root"
    system("mkdir -p " + _testlib.q(root + "/sub"))
    w = write_file(root + "/index.html", "hello\n")
    w = write_file(root + "/sub/index.html", "subfile\n")
    # 200000 bytes of 'x', byte-for-byte identical to the fixture the expectations were recorded against.
    system("head -c 200000 /dev/zero | tr '\\000' x > " + _testlib.q(root + "/big.bin"))

    port = _testlib.free_port()
    if port == 0 {
        print("SKIP http2 (no free port)")
        return 0
    }
    _testlib.bg_start(
        "nghttpd -v -d " + _testlib.q(root) + " -e --trailer 'x-trl: yes' --echo-upload" +
            " -m 2 -b 12 -w 12 -W 12 " + to_string(port) + " " + _testlib.q(key) + " " + _testlib.q(cert),
        tmp + "/server.log", tmp + "/pid_server")
    if not _testlib.wait_port(port, 50) {
        print("SKIP http2 (nghttpd not ready)")
        _testlib.show_head(tmp + "/server.log", 5)
        _testlib.kill_bg(tmp + "/pid_server")
        return 0
    }

    rgc = _testlib.rgc()
    bin_path = tmp + "/http2_test"
    rc = _testlib.run_rc(
        _testlib.q(rgc) + " " + _testlib.q(suite_dir + "/main.rg") + " -o " + _testlib.q(bin_path) +
            " > " + _testlib.q(tmp + "/build.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL http2 (compile)")
        _testlib.show_head(tmp + "/build.log", 20)
        _testlib.kill_bg(tmp + "/pid_server")
        return 1
    }

    out_path = tmp + "/out.log"
    rc = _testlib.run_rc(
        "timeout 60 " + _testlib.q(bin_path) + " --port " + to_string(port) +
            " --ca " + _testlib.q(cert) + " > " + _testlib.q(out_path) + " 2>&1 < /dev/null",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL http2 (run, exit=" + to_string(rc) + ")")
        _testlib.show_head(out_path, 40)
        print("--- server log")
        _testlib.show_tail(tmp + "/server.log", 20)
        _testlib.kill_bg(tmp + "/pid_server")
        return 1
    }

    want = _testlib.readf(suite_dir + "/expected")
    got = _testlib.readf(out_path)
    _testlib.kill_bg(tmp + "/pid_server")
    if not _testlib.str_eq(want, got) {
        print("FAIL http2 (output)")
        wl = want.split("\n")
        gl = got.split("\n")
        total = wl.len()
        if gl.len() > total {
            total = gl.len()
        }
        i = 0
        shown = 0
        while i < total and shown < 20 {
            lw = ""
            lg = ""
            if i < wl.len() {
                lw = wl.get(i)
            }
            if i < gl.len() {
                lg = gl.get(i)
            }
            if not _testlib.str_eq(lw, lg) {
                print("  line " + to_string(i + 1) + ":")
                print("  - " + lw)
                print("  + " + lg)
                shown = shown + 1
            }
            i = i + 1
        }
        print("--- server log")
        _testlib.show_tail(tmp + "/server.log", 20)
        return 1
    }
    print("PASS http2 (ALPN/HPACK/flow control/trailers/HttpClient)")
    return 0
}

def main() -> int {
    suite_dir = args().get(1)
    if not _testlib.have_tool("nghttpd") {
        print("SKIP http2 (nghttpd unavailable)")
        return 0
    }
    if not _testlib.have_tool("openssl") {
        print("SKIP http2 (openssl unavailable)")
        return 0
    }
    tmp = _testlib.mktmpd("h2")
    if tmp.len() == 0 {
        print("FAIL http2 (cannot create scratch directory)")
        return 1
    }
    rc = h2_run(tmp, suite_dir)
    system("rm -rf " + _testlib.q(tmp))
    return rc
}
