# bytes: binary-safe file I/O (NUL bytes, empty files, overwrite, errors)
# gzip: file-level compress/decompress helpers built on bytes.read_bytes/write_bytes

import bytes
import gzip

def main() {
    path = "/tmp/rgc_stdlib_bytes_io.bin"

    b = bytes.bytes_new(6)
    b.push(0)
    b.push(1)
    b.push(0)
    b.push(255)
    b.push(10)
    b.push(65)
    w = bytes.write_bytes(path, @b)
    print("write", w.ok, w.size)

    r = bytes.read_bytes(path)
    print("read", r.ok, r.size, r.data.len)
    d = r.data
    print("bytes", d.get(0), d.get(1), d.get(2), d.get(3), d.get(4), d.get(5))

    empty = bytes.bytes_new(0)
    epath = "/tmp/rgc_stdlib_bytes_io_empty.bin"
    we = bytes.write_bytes(epath, @empty)
    print("write_empty", we.ok, we.size)
    re = bytes.read_bytes(epath)
    print("read_empty", re.ok, re.size, re.data.len)

    small = bytes.bytes_from_str("hi")
    w2 = bytes.write_bytes(path, @small)
    r2 = bytes.read_bytes(path)
    print("overwrite", w2.ok, r2.ok, r2.size)

    missing = bytes.read_bytes("/rgc_no_such_dir/none.bin")
    print("missing", missing.ok, missing.error)
    wm = bytes.write_bytes("/rgc_no_such_dir/none.bin", @b)
    print("write_missing", wm.ok, wm.error)

    text = bytes.bytes_from_str("file gzip payload file gzip payload")
    gzpath = "/tmp/rgc_stdlib_bytes_io.bin.gz"
    c = gzip.compress_to_file(@text, gzpath, 9)
    print("gz_compress", c.ok, c.data.len > 0)
    g = gzip.decompress_file(gzpath)
    print("gz_read", g.ok, g.data.len, g.members, g.data.to_str())

    gl = gzip.decompress_file_limit(gzpath, 4)
    print("gz_limit", gl.ok, gl.error)
    go = gzip.decompress_file_limit(gzpath, 0)
    print("gz_limit_zero", go.ok, go.data.len)

    gm = gzip.decompress_file("/rgc_no_such_dir/none.gz")
    print("gz_missing", gm.ok, gm.error)
    gw = gzip.compress_to_file(@text, "/rgc_no_such_dir/none.gz", 6)
    print("gz_write_missing", gw.ok, gw.error)

    bin = bytes.bytes_new(4)
    bin.push(0)
    bin.push(0)
    bin.push(255)
    bin.push(0)
    bpath = "/tmp/rgc_stdlib_bytes_io_bin.gz"
    cb = gzip.compress_to_file(@bin, bpath, 0)
    rb = gzip.decompress_file(bpath)
    print("gz_binary", cb.ok, rb.ok, rb.data.len, rb.data.get(2))
}
