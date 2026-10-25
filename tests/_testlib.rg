# _testlib.rg — shared helpers for the tests/*/suite.rg harnesses.
#
# `rgc test` compiles each suite with RGC_STD extended to include tests/, so every suite can
# `import _testlib`. The leading underscore keeps the test walker from treating this as a case.
#
# Process control goes through system(); RGC has no readdir/spawn API of its own, which matches
# the approach used by the compiler (fmt) and rack.

import os
import net
import string
import time

# Mutable failure counter (scalars cannot be passed as @var).
public class Counts {
    fails: int
}

public def new_counts() -> Counts {
    c = Counts()
    c.fails = 0
    return c
}

# String content equality (runtime `==` on strings compares pointers).
public def str_eq(a: str, b: str) -> bool {
    if a.len() != b.len() {
        return False
    }
    return a.contains(b)
}

# Quote a value for safe interpolation into a shell command line.
public def q(s: str) -> str {
    return "'" + s + "'"
}

public def readf(path: str) -> str {
    r = read_file(path)
    if r.is_ok() {
        return r.unwrap()
    }
    return ""
}

public def read_trim(path: str) -> str {
    return string.trim(readf(path))
}

# Run cmd through the shell and capture its real exit status in rc_path.
# (system() maps signal deaths to 0; `echo $?` preserves the 128+sig convention.)
public def run_rc(cmd: str, rc_path: str) -> int {
    system(cmd + "; echo $? > " + q(rc_path))
    v = read_trim(rc_path).to_int()
    if v.is_ok() {
        return v.unwrap()
    }
    return -1
}

# The compiler under test, as provided by `rgc test` (fallback: repo-relative default).
public def rgc() -> str {
    m = os.getenv("RGC")
    if not m.is_nothing() {
        g = m.unwrap()
        if g.len() > 0 {
            return g
        }
    }
    return "build/rgc"
}

public def have_tool(name: str) -> bool {
    return system("command -v " + name + " >/dev/null 2>&1") == 0
}

# Create a unique scratch directory; returns its path (empty on failure).
public def mktmpd(tag: str) -> str {
    scratch = "/tmp/.rgc_suite_" + tag + "_dir"
    system("mktemp -d /tmp/rgc_" + tag + ".XXXXXX > " + q(scratch))
    return read_trim(scratch)
}

# Directory part of a path.
public def dirname(p: str) -> str {
    i = string.rfind(p, "/")
    if i < 0 {
        return "."
    }
    if i == 0 {
        return "/"
    }
    return p.slice(0, i)
}

# Pick a free TCP port: bind to port 0, read the assigned port, close again.
public def free_port() -> int {
    l = net.listen_on("127.0.0.1", 0)
    if not l.ok {
        return 0
    }
    listener = l.listener
    port = listener.local_port()
    listener.close()
    return port
}

# Poll until a local TCP port accepts connections (server readiness probe).
public def wait_port(port: int, tries: int) -> bool {
    i = 0
    while i < tries {
        c = net.connect_to("127.0.0.1", port)
        if c.ok {
            c.stream.close()
            return True
        }
        time.sleep(0.1)
        i = i + 1
    }
    return False
}

# Start a background process; its pid is recorded in pid_path for kill_bg().
public def bg_start(cmd: str, log_path: str, pid_path: str) {
    system("(" + cmd + " ) > " + q(log_path) + " 2>&1 & echo $! > " + q(pid_path))
}

public def kill_bg(pid_path: str) {
    pid = read_trim(pid_path)
    if pid.len() > 0 {
        system("kill " + pid + " 2>/dev/null")
    }
}

# Print the first/last non-empty lines of a log file, indented.
public def show_head(path: str, n: int) {
    lines = readf(path).split("\n")
    i = 0
    shown = 0
    while i < lines.len() and shown < n {
        t = string.trim(lines.get(i))
        if t.len() > 0 {
            print("  " + t)
            shown = shown + 1
        }
        i = i + 1
    }
}

public def show_tail(path: str, n: int) {
    lines = readf(path).split("\n")
    total = lines.len()
    start = total - n * 2
    if start < 0 {
        start = 0
    }
    shown = 0
    while start < total and shown < n {
        t = string.trim(lines.get(start))
        if t.len() > 0 {
            print("  " + t)
            shown = shown + 1
        }
        start = start + 1
    }
}

# Any output line starting with prefix (grep -q '^prefix' equivalent).
public def out_has_line(out: str, prefix: str) -> bool {
    for ln in out.split("\n") {
        if ln.startswith(prefix) {
            return True
        }
    }
    return False
}

# Any line starting with prefix and also containing marker.
public def out_has_line_with(out: str, prefix: str, marker: str) -> bool {
    for ln in out.split("\n") {
        if ln.startswith(prefix) and ln.contains(marker) {
            return True
        }
    }
    return False
}
