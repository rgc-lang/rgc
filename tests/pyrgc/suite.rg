# pyrgc suite: build the pyrgc_demo CPython extension and verify it with a real interpreter
# import. pyrgc exists to serve CPython, so python3 is the feature's own runtime here — the
# harness itself is RGC and no foreign test files are committed.
#
# Run by `rack test tests/pyrgc`; SKIP when python3 or the pyrgc checkout is unavailable.

import _testlib
import os

# pyrgc is its own repository, so it is either vendored inside this checkout, checked out
# beside it, or pointed at explicitly. PYTHONPATH must reach the directory that *contains*
# the pyrgc package, not the package itself.
def pyrgc_pkg(root: str) -> str {
    env = os.getenv("PYRGC")
    if not env.is_nothing() {
        e = env.unwrap()
        if e.len() > 0 {
            return e
        }
    }
    cands = List[str]()
    cands.push(root + "/pyrgc")
    cands.push(_testlib.dirname(root) + "/pyrgc")
    for cand in cands {
        if system("test -d " + _testlib.q(cand + "/pyrgc") + " >/dev/null 2>&1") == 0 {
            return cand
        }
    }
    return ""
}

def main() -> int {
    suite_dir = args().get(1)
    root = _testlib.dirname(_testlib.dirname(suite_dir))
    if not _testlib.have_tool("python3") {
        print("SKIP pyrgc (python3 unavailable)")
        return 0
    }
    pkg = pyrgc_pkg(root)
    if pkg.len() == 0 {
        print("SKIP pyrgc (no pyrgc checkout; set PYRGC=<dir containing the pyrgc package>)")
        return 0
    }
    tmp = _testlib.mktmpd("pyrgc")
    if tmp.len() == 0 {
        print("FAIL pyrgc (cannot create scratch directory)")
        return 1
    }
    rgc = _testlib.rgc()
    out = root + "/build/pyrgc_test"
    system("mkdir -p " + _testlib.q(root + "/build"))

    os.setenv("PYTHONPATH", pkg)
    rc = _testlib.run_rc(
        "python3 -m pyrgc build " + _testlib.q(root + "/examples/pyrgc_demo.rg") +
            " -n pyrgc_demo -o " + _testlib.q(out) + " --rgc " + _testlib.q(rgc) +
            " > " + _testlib.q(tmp + "/build.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL pyrgc_demo (build)")
        _testlib.show_head(tmp + "/build.log", 20)
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    probe = "import sys; sys.path.insert(0, sys.argv[1]); import pyrgc_demo as m; " +
        "assert m.add(3, 4) == 7; assert m.add(-2, 2) == 0; " +
        "assert m.greet('rgc') == 'hello, rgc!'; " +
        "assert m.is_even(10) is True; assert m.is_even(7) is False; " +
        "assert abs(m.dist(0, 0, 3, 4) - 5.0) < 1e-9; assert m.say_hi() is None; " +
        "print('pyrgc probe ok')"
    rc = _testlib.run_rc(
        "python3 -c \"" + probe + "\" " + _testlib.q(out) +
            " > " + _testlib.q(tmp + "/probe.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL pyrgc_demo (import checks)")
        _testlib.show_head(tmp + "/probe.log", 20)
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    print("PASS pyrgc_demo (build + CPython import)")
    system("rm -rf " + _testlib.q(tmp))
    return 0
}
