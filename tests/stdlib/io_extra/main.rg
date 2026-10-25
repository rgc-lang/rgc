import io

def main() -> int {
    path = "/tmp/rgc_stdlib_io_extra.txt"
    remove_file(path)
    print("exists0 =", exists(path))
    print("write =", write_file(path, "a\n").is_ok())
    print("append =", io.append_file(path, "b\n").is_ok())
    print("exists1 =", io.exists(path))
    match read_file(path) {
        case Ok(content) => print(content)
        case Err(msg) => print("read failed:", msg)
    }
    print("remove =", io.remove_file(path).is_ok())
    print("exists2 =", exists(path))
    return 0
}
