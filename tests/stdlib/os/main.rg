import os

def main() {
    print("missing", os.getenv("RGC_STDLIB_MISSING").is_nothing())
    os.setenv("RGC_STDLIB_OS", "yes")
    print("get", os.getenv("RGC_STDLIB_OS").unwrap())
    print("cwd_ok", os.getcwd().is_ok())
    print("system_ok", os.system("true") == 0)
    print("exiting")
    os.exit(7)
    print("unreachable")
}
