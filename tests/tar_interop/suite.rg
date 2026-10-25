# tar interop suite (pure RGC): the system GNU tar creates ustar/pax/gnu archives that the
# RGC tar module lists and extracts; RGC-created archives (plain and .tar.gz) are read back
# by system tar. Covers ustar prefix names, GNU LongLink, PAX path records, symlinks,
# directories, empty files, binary payloads and .tar.gz.
#
# Run by `rgc test tests/tar_interop`; SKIP when tar/gzip are unavailable.

import _testlib
import bytes
import gzip
import tar

def rep(s: str, n: int) -> str {
    out = ""
    i = 0
    while i < n {
        out = out + s
        i = i + 1
    }
    return out
}

def hash_str(s: str) -> int {
    h = 0
    i = 0
    while i < s.len() {
        h = (h * 131 + s.char_at(i)) % 1000000007
        i = i + 1
    }
    return h
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

def t_fail(what: str, detail: str, counts: @Counts) {
    print("FAIL tar_interop " + what + " (" + detail + ")")
    counts.fails = counts.fails + 1
}

# ---- reading system-tar archives --------------------------------------------

class WantEntry {
    name: str
    size: int
    kind: int
}

def we(name: str, size: int, kind: int) -> WantEntry {
    w = WantEntry()
    w.name = name
    w.size = size
    w.kind = kind
    return w
}

# Every expected entry must appear exactly once; no extras allowed.
def check_entries(tag: str, res: @TarResult, want: @List[WantEntry], counts: @Counts) {
    if not res.ok {
        t_fail(tag, "list failed: " + res.error, @var counts)
        return
    }
    used = List[bool]()
    i = 0
    while i < want.len() {
        used.push(False)
        i = i + 1
    }
    i = 0
    while i < res.entries.len() {
        e = res.entries.get(i)
        found = -1
        k = 0
        while k < want.len() {
            if not used.get(k) and hash_str(e.name) == hash_str(want.get(k).name) and
                    e.size == want.get(k).size and e.kind == want.get(k).kind {
                found = k
                k = want.len()
            }
            k = k + 1
        }
        if found < 0 {
            t_fail(tag, "unexpected entry '" + e.name + "' kind=" + to_string(e.kind), @var counts)
        } else {
            used.set(found, True)
        }
        i = i + 1
    }
    i = 0
    while i < want.len() {
        if not used.get(i) {
            t_fail(tag, "missing entry '" + want.get(i).name + "'", @var counts)
        }
        i = i + 1
    }
}

def load_arch(tag: str, path: str, counts: @Counts) -> Bytes {
    r = bytes.read_bytes(path)
    if not r.ok {
        t_fail(tag, "cannot read " + path, @var counts)
        return bytes.bytes_new(0)
    }
    return r.data
}

def main() -> int {
    if not _testlib.have_tool("tar") {
        print("SKIP tar_interop (tar unavailable)")
        return 0
    }
    if not _testlib.have_tool("gzip") {
        print("SKIP tar_interop (gzip unavailable)")
        return 0
    }
    tmp = _testlib.mktmpd("tar")
    if tmp.len() == 0 {
        print("FAIL tar_interop (cannot create scratch directory)")
        return 1
    }
    counts = _testlib.new_counts()
    system("umask 022")

    # ---- fixture tree created by plain shell primitives, archived by system tar ----
    src = tmp + "/src"
    ustar_long = "pkg/" + rep("a", 90) + "/" + rep("b", 90) + ".txt"
    pax_long = "pax/" + rep("b", 180) + ".txt"
    gnu_long = "gnu/" + rep("c", 140) + ".txt"
    system("mkdir -p " + _testlib.q(src + "/pkg/logs") + " " + _testlib.q(src + "/pax") + " " +
        _testlib.q(src + "/gnu") + " " + _testlib.q(src + "/pkg/" + rep("a", 90)))
    w = write_file(src + "/pkg/data.txt", "hello tar\n")
    w = write_file(src + "/pkg/empty", "")
    bin = bytes.bytes_new(4)
    bin.push(0)
    bin.push(1)
    bin.push(0)
    bin.push(255)
    wb = bytes.write_bytes(src + "/pkg/bin.dat", @bin)
    w = write_file(src + "/" + ustar_long, "ustar long\n")
    w = write_file(src + "/" + pax_long, "pax long\n")
    w = write_file(src + "/" + gnu_long, "gnu long\n")
    system("ln -s target " + _testlib.q(src + "/gnu/link"))

    rc = _testlib.run_rc(
        "tar --format=ustar -cf " + _testlib.q(tmp + "/ustar.tar") + " -C " + _testlib.q(src) +
            " pkg > " + _testlib.q(tmp + "/tar1.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP tar_interop (system tar failed to build the ustar fixture)")
        _testlib.show_head(tmp + "/tar1.log", 5)
        system("rm -rf " + _testlib.q(tmp))
        return 0
    }
    rc = _testlib.run_rc(
        "tar --format=pax -cf " + _testlib.q(tmp + "/pax.tar") + " -C " + _testlib.q(src) +
            " pkg pax > " + _testlib.q(tmp + "/tar2.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP tar_interop (system tar failed to build the pax fixture)")
        _testlib.show_head(tmp + "/tar2.log", 5)
        system("rm -rf " + _testlib.q(tmp))
        return 0
    }
    rc = _testlib.run_rc(
        "tar --format=gnu -cf " + _testlib.q(tmp + "/gnu.tar") + " -C " + _testlib.q(src) +
            " pkg gnu > " + _testlib.q(tmp + "/tar3.log") + " 2>&1",
        tmp + "/rc")
    if rc != 0 {
        print("SKIP tar_interop (system tar failed to build the gnu fixture)")
        _testlib.show_head(tmp + "/tar3.log", 5)
        system("rm -rf " + _testlib.q(tmp))
        return 0
    }
    system("gzip -n -c " + _testlib.q(tmp + "/ustar.tar") + " > " + _testlib.q(tmp + "/targz.tar.gz"))

    ustar_data = bytes.bytes_from_str("ustar long\n")
    pax_data = bytes.bytes_from_str("pax long\n")
    gnu_data = bytes.bytes_from_str("gnu long\n")

    # ---- RGC reads the system-created archives ----
    ustar = load_arch("ustar", tmp + "/ustar.tar", @var counts)
    pax = load_arch("pax", tmp + "/pax.tar", @var counts)
    gnu = load_arch("gnu", tmp + "/gnu.tar", @var counts)

    pkg_dir = we("pkg/", 0, 5)
    pkg_common = List[WantEntry]()
    pkg_common.push(pkg_dir)
    pkg_common.push(we("pkg/data.txt", 10, 0))
    pkg_common.push(we("pkg/bin.dat", 4, 0))
    pkg_common.push(we("pkg/empty", 0, 0))
    pkg_common.push(we("pkg/logs/", 0, 5))

    ustar_want = List[WantEntry]()
    i = 0
    while i < pkg_common.len() {
        ustar_want.push(pkg_common.get(i))
        i = i + 1
    }
    ustar_want.push(we("pkg/" + rep("a", 90) + "/", 0, 5))
    ustar_want.push(we(ustar_long, 11, 0))

    pax_want = List[WantEntry]()
    i = 0
    while i < pkg_common.len() {
        pax_want.push(pkg_common.get(i))
        i = i + 1
    }
    pax_want.push(we("pkg/" + rep("a", 90) + "/", 0, 5))
    pax_want.push(we(ustar_long, 11, 0))
    pax_want.push(we("pax/", 0, 5))
    pax_want.push(we(pax_long, 9, 0))

    gnu_want = List[WantEntry]()
    i = 0
    while i < pkg_common.len() {
        gnu_want.push(pkg_common.get(i))
        i = i + 1
    }
    gnu_want.push(we("pkg/" + rep("a", 90) + "/", 0, 5))
    gnu_want.push(we(ustar_long, 11, 0))
    gnu_want.push(we("gnu/", 0, 5))
    gnu_want.push(we(gnu_long, 9, 0))
    gnu_want.push(we("gnu/link", 0, 2))

    ustar_res = tar.list_entries(@ustar)
    check_entries("ustar", @ustar_res, @ustar_want, @var counts)
    pax_res = tar.list_entries(@pax)
    check_entries("pax", @pax_res, @pax_want, @var counts)
    gnu_res = tar.list_entries(@gnu)
    check_entries("gnu", @gnu_res, @gnu_want, @var counts)

    # symlink metadata
    i = 0
    while i < gnu_res.entries.len() {
        e = gnu_res.entries.get(i)
        if e.kind == 2 {
            if not _testlib.str_eq(e.linkname, "target") {
                t_fail("gnu_link", "linkname='" + e.linkname + "'", @var counts)
            }
            if e.mode != 511 {
                t_fail("gnu_link", "mode=" + to_string(e.mode) + " want 511", @var counts)
            }
        }
        i = i + 1
    }

    # member extraction: content hash for each long name; symlink must be rejected
    ext = tar.extract(@ustar, ustar_long)
    ed = ext.data
    if not ext.ok or hash_bytes(@ed) != hash_bytes(@ustar_data) {
        t_fail("extract_ustar_long", "content mismatch", @var counts)
    }
    ext = tar.extract(@pax, pax_long)
    ed = ext.data
    if not ext.ok or hash_bytes(@ed) != hash_bytes(@pax_data) {
        t_fail("extract_pax_long", "content mismatch", @var counts)
    }
    ext = tar.extract(@gnu, gnu_long)
    ed = ext.data
    if not ext.ok or hash_bytes(@ed) != hash_bytes(@gnu_data) {
        t_fail("extract_gnu_long", "content mismatch", @var counts)
    }
    ext = tar.extract(@gnu, "gnu/link")
    if ext.ok or not ext.error.contains("not a regular file") {
        t_fail("extract_gnu_link", "symlink extraction should fail", @var counts)
    }

    # .tar.gz through the RGC gzip decoder, then the same entries as the plain tar
    gz_arch = load_arch("targz", tmp + "/targz.tar.gz", @var counts)
    dres = bytes.bytes_new(0)
    dec = gzip.decompress(@gz_arch)
    if not dec.ok {
        t_fail("targz", "gunzip failed: " + dec.error, @var counts)
    } else {
        dres = dec.data
        gz_res = tar.list_entries(@dres)
        check_entries("targz", @gz_res, @ustar_want, @var counts)
    }

    # ---- RGC writes, system tar reads back ----
    b = tar.builder()
    hello2 = bytes.bytes_from_str("hello from rgc tar\n")
    b.add_file("rgc/hello.txt", @hello2)
    b.add_file("rgc/bin.dat", @bin)
    b.add_dir("rgc/logs")
    b.add_file("rgc/" + rep("d", 130) + ".dat", @hello2)
    bres = b.finish()
    if not bres.ok {
        t_fail("build", "builder failed", @var counts)
    } else {
        rgc_tar = tmp + "/rgc.tar"
        bdata = bres.data
        wb = bytes.write_bytes(rgc_tar, @bdata)
        comp = gzip.compress(@bdata)
        cdata = comp.data
        rgc_targz = tmp + "/rgc.tar.gz"
        wb = bytes.write_bytes(rgc_targz, @cdata)

        # tar -tf lists exactly our four names, in the order we added them
        rc = _testlib.run_rc(
            "tar -tf " + _testlib.q(rgc_tar) + " > " + _testlib.q(tmp + "/tf.txt") + " 2>" +
                _testlib.q(tmp + "/tf.err"),
            tmp + "/rc")
        if rc != 0 {
            t_fail("tar_tf", "system tar cannot list the RGC archive", @var counts)
        } else {
            tf = _testlib.readf(tmp + "/tf.txt")
            want_tf = "rgc/hello.txt\nrgc/bin.dat\nrgc/logs/\nrgc/" + rep("d", 130) + ".dat\n"
            if not _testlib.str_eq(tf, want_tf) {
                t_fail("tar_tf", "listing mismatch:\n  got    '" + tf + "'\n  wanted '" + want_tf + "'", @var counts)
            }
        }

        # tar -xf unpacks the archive; verify contents and the directory entry
        system("mkdir -p " + _testlib.q(tmp + "/x"))
        rc = _testlib.run_rc(
            "tar -xf " + _testlib.q(rgc_tar) + " -C " + _testlib.q(tmp + "/x") + " 2>" +
                _testlib.q(tmp + "/xf.err"),
            tmp + "/rc")
        if rc != 0 {
            t_fail("tar_xf", "system tar cannot extract the RGC archive", @var counts)
        } else {
            hf = bytes.read_bytes(tmp + "/x/rgc/hello.txt").data
            if hash_bytes(@hf) != hash_bytes(@hello2) {
                t_fail("tar_xf", "hello.txt content mismatch", @var counts)
            }
            xb = bytes.read_bytes(tmp + "/x/rgc/bin.dat")
            if not xb.ok or xb.size != 4 {
                t_fail("tar_xf", "bin.dat size mismatch", @var counts)
            } else {
                if xb.data.get(0) != 0 or xb.data.get(1) != 1 or xb.data.get(2) != 0 or xb.data.get(3) != 255 {
                    t_fail("tar_xf", "bin.dat bytes mismatch", @var counts)
                }
            }
            if system("test -d " + _testlib.q(tmp + "/x/rgc/logs")) != 0 {
                t_fail("tar_xf", "rgc/logs is not a directory", @var counts)
            }
            lf = bytes.read_bytes(tmp + "/x/rgc/" + rep("d", 130) + ".dat").data
            if hash_bytes(@lf) != hash_bytes(@hello2) {
                t_fail("tar_xf", "long-name member content mismatch", @var counts)
            }
        }

        # the .tar.gz archive stays readable by system tar
        rc = _testlib.run_rc(
            "tar -ztf " + _testlib.q(rgc_targz) + " > " + _testlib.q(tmp + "/ztf.txt") + " 2>" +
                _testlib.q(tmp + "/ztf.err"),
            tmp + "/rc")
        if rc != 0 {
            t_fail("tar_ztf", "system tar cannot list the RGC .tar.gz archive", @var counts)
        }
    }

    system("rm -rf " + _testlib.q(tmp))
    if counts.fails > 0 {
        return 1
    }
    print("PASS tar_interop (ustar/pax/gnu + long names + symlink + .tar.gz, cross-checked with system tar)")
    return 0
}
