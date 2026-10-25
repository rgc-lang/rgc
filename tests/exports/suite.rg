# exports suite: `rgc --emit-exports` publishes the signature and str-ownership metadata that
# binding generators consume (pyrig). The ownership class decides whether the generated C glue
# may free() a returned str buffer, so a wrong answer is memory corruption rather than a wrong
# value — each classification is pinned against _fixture.rg here, whole JSON object per line so
# the format pyrig parses is pinned too.
#
# Run by `rack test tests/exports`.

import _testlib

# Count non-overlapping occurrences of needle in hay.
def count_occ(hay: str, needle: str) -> int {
    n = 0
    i = 0
    while i + needle.len() <= hay.len() {
        if _testlib.str_eq(hay.slice(i, i + needle.len()), needle) {
            n = n + 1
            i = i + needle.len()
        } else {
            i = i + 1
        }
    }
    return n
}

def expectations() -> List[str] {
    xs = List[str]()
    xs.push("{\"name\": \"lit\", \"public\": true, \"params\": [], \"ret\": \"str\", \"str_ret\": \"static\"}")
    xs.push("{\"name\": \"param\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"borrowed\"}")
    xs.push("{\"name\": \"concat\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"owned\"}")
    xs.push("{\"name\": \"via_local\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"owned\"}")
    xs.push("{\"name\": \"trailing\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"owned\"}")
    xs.push("{\"name\": \"branch_owned\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"owned\"}")
    xs.push("{\"name\": \"branch_mixed\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"unknown\"}")
    xs.push("{\"name\": \"via_call\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"unknown\"}")
    xs.push("{\"name\": \"reassigned\", \"public\": true, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"unknown\"}")
    xs.push("{\"name\": \"scalars\", \"public\": true, \"params\": [{\"name\": \"a\", \"type\": \"int\"}, {\"name\": \"b\", \"type\": \"float\"}, {\"name\": \"c\", \"type\": \"bool\"}], \"ret\": \"int\", \"str_ret\": \"\"}")
    xs.push("{\"name\": \"priv\", \"public\": false, \"params\": [{\"name\": \"s\", \"type\": \"str\"}], \"ret\": \"str\", \"str_ret\": \"owned\"}")
    return xs
}

def main() -> int {
    suite_dir = args().get(1)
    tmp = _testlib.mktmpd("exports")
    if tmp.len() == 0 {
        print("FAIL exports (cannot create scratch directory)")
        return 1
    }
    meta_path = tmp + "/exports.json"
    rc = _testlib.run_rc(
        _testlib.q(_testlib.rgc()) + " " + _testlib.q(suite_dir + "/_fixture.rg") +
            " --emit-object -o " + _testlib.q(tmp + "/fixture.o") +
            " --emit-exports " + _testlib.q(meta_path) +
            " > " + _testlib.q(tmp + "/rgc.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("FAIL exports (rgc --emit-exports)")
        _testlib.show_head(tmp + "/rgc.log", 20)
        system("rm -rf " + _testlib.q(tmp))
        return 1
    }

    meta = _testlib.readf(meta_path)
    fails = 0
    xs = expectations()
    i = 0
    while i < xs.len() {
        if not meta.contains(xs.get(i)) {
            print("FAIL exports: metadata is missing " + xs.get(i))
            fails = fails + 1
        }
        i = i + 1
    }
    # Every entry-file function must be listed exactly once, and nothing from an imported module.
    listed = count_occ(meta, ", \"public\": ")
    if listed != xs.len() {
        print("FAIL exports: listed " + to_string(listed) + " functions, expected " +
              to_string(xs.len()))
        fails = fails + 1
    }
    system("rm -rf " + _testlib.q(tmp))
    if fails > 0 {
        return 1
    }
    print("PASS exports (--emit-exports signatures + str ownership)")
    return 0
}
