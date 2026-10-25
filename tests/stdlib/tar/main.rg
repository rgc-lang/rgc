# tar: pure-RGC archive writer/reader (ustar headers, GNU LongLink, directories, errors)

import bytes
import tar

def main() {
    hello = bytes.bytes_from_str("hello tar\n")
    empty = bytes.bytes_new(0)

    b = tar.builder()
    b.add_file("dir/hello.txt", @hello)
    b.add_file("dir/empty", @empty)
    b.add_dir("dir/logs")
    b.add_file_mode("dir/run.sh", @hello, 493, 12345)
    long_name = "dir/"
    i = 0
    while i < 130 {
        long_name = long_name + "x"
        i = i + 1
    }
    b.add_file(long_name, @hello)
    made = b.finish()
    print("create", made.ok, made.data.len > 0, made.data.len % 512 == 0)

    a = made.data
    l = tar.list_entries(@a)
    print("list", l.ok, l.entries.len())

    e0 = l.entries.get(0)
    print("file", e0.name, e0.size, e0.kind, e0.mode)
    e1 = l.entries.get(1)
    print("empty_entry", e1.name, e1.size, e1.kind)
    e2 = l.entries.get(2)
    print("dir", e2.name, e2.kind, e2.mode)
    e3 = l.entries.get(3)
    print("mode", e3.name, e3.mode, e3.mtime)
    e4 = l.entries.get(4)
    print("long", e4.name == long_name, e4.size, e4.kind)

    f = tar.extract(@a, "dir/hello.txt")
    print("extract", f.ok, f.entry.size, f.data.len, f.data.get(0))

    fe = tar.extract(@a, "dir/empty")
    print("extract_empty", fe.ok, fe.entry.size, fe.data.len)

    fd = tar.extract(@a, "dir/logs/")
    print("extract_dir", fd.ok, fd.error)

    fm = tar.extract(@a, "dir/missing")
    print("extract_missing", fm.ok, fm.error)

    zeros = bytes.bytes_new(1024)
    lz = tar.list_entries(@zeros)
    print("empty_archive", lz.ok, lz.entries.len())

    bad = a.slice(0, a.len)
    bad.set(0, bad.get(0) ^ 1)
    lb = tar.list_entries(@bad)
    print("bad_sum", lb.ok, lb.error)

    short_header = a.slice(0, 100)
    lh = tar.list_entries(@short_header)
    print("trunc_header", lh.ok, lh.error)

    short_data = a.slice(0, 520)
    ld = tar.list_entries(@short_data)
    print("trunc_data", ld.ok, ld.error)

    xs = List[TarInput]()
    x = TarInput()
    x.name = "one.txt"
    x.data = bytes.bytes_from_str("1")
    x.kind = 0
    x.mode = 0
    x.mtime = 0
    xs.push(x)
    direct = tar.create(@xs)
    print("direct", direct.ok, direct.data.len % 512 == 0)
    da = direct.data
    dl = tar.list_entries(@da)
    print("direct_list", dl.ok, dl.entries.len())
    de = dl.entries.get(0)
    print("direct_entry", de.name, de.size, de.mode)

    ys = List[TarInput]()
    y = TarInput()
    y.name = ""
    y.data = bytes.bytes_new(0)
    y.kind = 0
    y.mode = 420
    y.mtime = 0
    ys.push(y)
    ce = tar.create(@ys)
    print("bad_name", ce.ok, ce.error)

    zs = List[TarInput]()
    z = TarInput()
    z.name = "link"
    z.data = bytes.bytes_new(0)
    z.kind = 2
    z.mode = 420
    z.mtime = 0
    zs.push(z)
    ck = tar.create(@zs)
    print("bad_kind", ck.ok, ck.error)

    b2 = tar.builder()
    b2.add_file("x.txt", @hello)
    r2 = tar.create_from(b2)
    print("create_from", r2.ok, r2.data.len % 512 == 0)
}
