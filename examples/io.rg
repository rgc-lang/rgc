# Standard library: io builtin module read_file / write_file (returns Result)

import io

def main() {
    path = "/tmp/rgc_io_test.txt"

    # Write to a file
    wr = write_file(path, "hello from RGC\nline 2\n")
    print("write is_ok =", wr.is_ok())
    match wr {
        case Ok(v) => print("write succeeded")
        case Err(msg) => print("write failed:", msg)
    }

    # Read from a file
    fr = read_file(path)
    print("read is_ok =", fr.is_ok())
    match fr {
        case Ok(content) => print("read content:", content)
        case Err(msg) => print("read failed:", msg)
    }

    # Reading a non-existent file -> Err
    bad = read_file("/tmp/definitely_missing_xyz.rg")
    print("bad is_err =", bad.is_err())
    match bad {
        case Ok(content) => print("unexpected:", content)
        case Err(msg) => print("bad read error:", msg)
    }
}