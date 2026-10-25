# pyrig suite: build the pyrig_demo CPython extension and verify it with a real interpreter
# import. pyrig exists to serve CPython, so python3 is the feature's own runtime here — the
# harness itself is RGC and no foreign test files are committed.
#
# Run by `rgc test tests/pyrig`; SKIP when python3 is unavailable.

import _testlib
import os

def main() -> int {
    suite_dir = args().get(1)
    root = _testlib.dirname(_testlib.dirname(suite_dir))
    if not _testlib.have_tool("python3") {
        print("SKIP pyrig (python3 unavailable)")
        return 0
    }
    tmp = _testlib.mktmpd("pyrig")
    if tmp.len() == 0 {
        print("FAIL pyrig (cannot create scratch directory)")
        return 1
    }
    rgc = _testlib.rgc()
    out = root + "/build/pyrig_test"
    system("mkdir -p " + _testlib.q(root + "/build"))

    os.setenv("PYTHONPATH", root + "/pyrig")
    rc = _testlib.run_rc(
        "python3 -m pyrig build " + _testlib.q(root + "/examples/pyrig_demo.rg") +
            " -n pyrig_demo -o " + _testlib.q(out) + " --rgc " + _testlib.q(rgc) +
            " > " + _testlib.q(tmp + "/build.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL pyrig_demo (build)")
        _testlib.show_head(tmp + "/build.log", 20)
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    probe = "import sys; sys.path.insert(0, sys.argv[1]); import pyrig_demo as m; " +
        "assert m.add(3, 4) == 7; assert m.add(-2, 2) == 0; " +
        "assert m.greet('rgc') == 'hello, rgc!'; " +
        "assert m.is_even(10) is True; assert m.is_even(7) is False; " +
        "assert abs(m.dist(0, 0, 3, 4) - 5.0) < 1e-9; assert m.say_hi() is None; " +
        "print('pyrig probe ok')"
    rc = _testlib.run_rc(
        "python3 -c \"" + probe + "\" " + _testlib.q(out) +
            " > " + _testlib.q(tmp + "/probe.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL pyrig_demo (import checks)")
        _testlib.show_head(tmp + "/probe.log", 20)
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    print("PASS pyrig_demo (build + CPython import)")
    system("rm -rf " + _testlib.q(tmp))
    return 0
}
