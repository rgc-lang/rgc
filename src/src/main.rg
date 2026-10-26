# RGC compiler entry point
#
# CLI (rustc-style):
#   rgc <file.rg> [-o <output>] [-O|-O2|-O0] [-g]   # compile and link directly
#   rgc run <file.rg> [args...]     # compile and run
#   rgc ast-dump <file.rg>          # parse only
#   rgc <file.rg> --emit-exports <json>   # function metadata for binding generators (pyrig)
#
# rgc only compiles: test running lives in the toolchain (`rack test`, see ../rack).
#
# Optimization modes: release by default (LLVM O2); -O/-O2 explicitly select release;
# -O0 disables optimization; -g emits DWARF debug info (usually combined with -O0).
#
# Backend: emits LLVM IR text; the embedded LLVM generates an object file in-process and g++ links.

import util
import types
import token
import ast
import lexer
import parser
import sema
import ir
import diag
import modules
import fmt
import exports

# Read file content; on failure continue with an empty source.
public def read_source(path: str) -> str {
    r = read_file(path)
    if r.is_ok() {
        return r.unwrap()
    }
    return ""
}

# Resolve a diagnostic's module attribute to a file path: sema records the module name (empty for the entry),
# mapped to an actual path via the loader's module_paths before rendering; unknown modules fall back to the entry file.
# Note: List.get returns a copy; after mutating fields you must write them back with set.
public def resolve_diag_files(loader: @var ModuleLoader, s: @var Sema, entry_path: str) {
    i = 0
    while i < s.diag_items.len() {
        it = s.diag_items.get(i)
        if it.file.len() > 0 and loader.module_paths.contains(it.file) {
            it.file = loader.module_paths.get(it.file)
        } else {
            it.file = entry_path
        }
        s.diag_items.set(i, it)
        i = i + 1
    }
}

# Render sema diagnostics plus a rustc-style summary line.
def render_sema_errors(loader: @var ModuleLoader, s: @var Sema, src_path: str, src: str) {
    resolve_diag_files(@var loader, @var s, src_path)
    items = s.diag_items
    write_stderr(diag_render_multi(src_path, src, @items))
    if s.diag_errors == 1 {
        write_stderr("error: aborting due to 1 previous error\n")
    } else {
        write_stderr("error: aborting due to " + to_string(s.diag_errors) +
                     " previous errors\n")
    }
}

# Compile and link. opt_level: 0=no optimization, 2=O2; debug_info: 1=emit DWARF.
# emit_obj: generate an object file only, without linking (--emit-object);
# shared_link: link as a shared library (--shared, used by pyrig to build Python extensions);
# exports_path: also write function metadata as JSON (--emit-exports, consumed by pyrig).
public def compile_and_link(src_path: str, output: str, emit_llvm: bool,
                     link_args: str, opt_level: int, debug_info: bool,
                     emit_obj: bool, shared_link: bool, exports_path: str) -> int {
    r0 = read_file(src_path)
    if not r0.is_ok() {
        write_stderr("error: cannot read " + src_path + "\n")
        return 1
    }
    src = r0.unwrap()
    loader = make_module_loader(src_path)
    stmts = loader_load_entry(@var loader, src)
    if not loader.ok {
        if loader.error_msg.len() > 0 {
            write_stderr(loader.error_msg)
        }
        return 1
    }

    s = make_sema()
    s.diag_source_name = src_path
    s.diag_source = src
    sema_check_program(@var s, @stmts)
    if s.diag_errors > 0 {
        render_sema_errors(@var loader, @var s, src_path, src)
        write_stderr("compilation failed.\n")
        return 1
    }

    if exports_path.len() > 0 {
        if exports_emit(exports_path, @stmts, src_path) != 0 {
            return 1
        }
    }

    g = make_irgen(@var s)
    g.source_path = src_path
    g.opt_level = opt_level
    g.win_dll_export = shared_link and host_is_windows()
    if debug_info {
        g.debug_info = 1
    }
    ll_text = irg_generate(@var g, stmts)

    if emit_llvm {
        wr0 = write_file(output, ll_text)
        match wr0 {
            case Ok(n) => None
            case Err(msg) => print("error: cannot write " + output + ": " + msg)
        }
        return 0
    }

    if emit_obj {
        wr = emit_object(ll_text, output)
        if wr != 0 {
            write_stderr("codegen failed.\n")
            return 1
        }
        return 0
    }

    obj_path = output + ".o"
    cc = emit_object(ll_text, obj_path)
    if cc != 0 {
        write_stderr("codegen failed.\n")
        return 1
    }
    qobj = shell_quote(obj_path)
    qout = shell_quote(output)
    if host_is_windows() {
        # Winsock, Win32 thread/console APIs, and BCrypt (entropy) come from system import libraries; the CRT is linked by default.
        link_cmd = "g++ -g " + qobj + " -o " + qout + " -lws2_32 -lbcrypt"
        if shared_link {
            link_cmd = "g++ -shared -g " + qobj + " -o " + qout + " -lws2_32 -lbcrypt"
        }
    } else {
        link_cmd = "g++ -g " + qobj + " -lm -lpthread -o " + qout
        if shared_link {
            link_cmd = "g++ -shared -fPIC -g " + qobj + " -lm -lpthread -o " + qout
        }
    }
    if link_args.len() > 0 {
        link_cmd = link_cmd + " " + link_args
    }
    rc = system(link_cmd)
    if rc != 0 {
        write_stderr("link failed.\n")
        return 1
    }
    remove_file(obj_path)
    print("built: " + output)
    return 0
}

# Compile to a temporary file and run.
public def run_program(src_path: str, extra_args: str) -> int {
    tmp = "/tmp/rgc_run"
    if host_is_windows() {
        # MinGW appends .exe when the output name has no suffix; spawn it directly from the cwd.
        tmp = ".rgc_run.exe"
    }
    rc = compile_and_link(src_path, tmp, False, "", 2, False, False, False, "")
    if rc != 0 {
        return 1
    }
    cmd = tmp
    if extra_args.len() > 0 {
        cmd = cmd + " " + extra_args
    }
    rc = system(cmd)
    remove_file(tmp)
    if rc != 0 {
        return 1
    }
    return 0
}

# The check subcommand loads modules and runs type/borrow checks without generating code.
public def check_program(src_path: str) -> int {
    r0 = read_file(src_path)
    if not r0.is_ok() {
        write_stderr("error: cannot read " + src_path + "\n")
        return 1
    }
    src = r0.unwrap()
    loader = make_module_loader(src_path)
    stmts = loader_load_entry(@var loader, src)
    if not loader.ok {
        if loader.error_msg.len() > 0 {
            write_stderr(loader.error_msg)
        }
        return 1
    }
    s = make_sema()
    s.diag_source_name = src_path
    s.diag_source = src
    sema_check_program(@var s, @stmts)
    if s.diag_errors > 0 {
        render_sema_errors(@var loader, @var s, src_path, src)
        write_stderr("check failed.\n")
        return 1
    }
    print("check ok: " + src_path)
    return 0
}

public def main() -> int {
    argv = args()
    if argv.len() < 2 {
        print("RGC compiler")
        print("Usage (rustc-style):")
        print("  rgc <file.rg> [-o <output>]     # compile directly")
        print("  rgc <file.rg> --emit-object      # compile to object file")
        print("  rgc <file.rg> --shared           # compile to shared library")
        print("  rgc <file.rg> --emit-exports <json>  # also write function metadata for binding generators")
        print("  rgc run <file.rg> [args...]     # compile & run with args")
        print("  rgc check <file.rg>             # type/borrow check only, no codegen")
        print("  rgc fmt <file.rg> [...] [--check]  # format in place; --check reports only")
        print("  rgc ast-dump <file.rg>              # parse only")
        return 1
    }
    first = argv.get(1)

    if str_eq(first, "fmt") {
        files = List[str]()
        check_only = False
        i = 2
        while i < argv.len() {
            if str_eq(argv.get(i), "--check") {
                check_only = True
            } elif not argv.get(i).startswith("--") {
                files.push(argv.get(i))
            }
            i = i + 1
        }
        if files.len() == 0 {
            print("usage: rgc fmt <file.rg> [...] [--check]")
            return 1
        }
        return fmt_files(files, check_only)
    }

    if str_eq(first, "check") {
        if argv.len() < 3 {
            print("usage: rgc check <file.rg>")
            return 1
        }
        return check_program(argv.get(2))
    }

    if str_eq(first, "ast-dump") {
        if argv.len() < 3 {
            print("usage: rgc ast-dump <file.rg>")
            return 1
        }
        r0 = read_file(argv.get(2))
        if not r0.is_ok() {
            write_stderr("error: cannot read " + argv.get(2) + "\n")
            return 1
        }
        src = r0.unwrap()
        loader = make_module_loader(argv.get(2))
        stmts = loader_load_entry(@var loader, src)
        if not loader.ok {
            if loader.error_msg.len() > 0 {
                write_stderr(loader.error_msg)
            }
            return 1
        }
        print("Parsed " + to_string(stmts.len()) + " top-level statements.")
        return 0
    }

    if str_eq(first, "test") {
        print("error: `test` is not a compiler command — the compiler only compiles")
        print("hint: tests are run by the toolchain: RGC=<compiler> rack test <path ...>")
        return 1
    }

    if str_eq(first, "run") {
        if argv.len() < 3 {
            print("usage: rgc run <file.rg> [args...]")
            return 1
        }
        extra = ""
        i = 3
        while i < argv.len() {
            if i > 3 {
                extra = extra + " "
            }
            extra = extra + argv.get(i)
            i = i + 1
        }
        return run_program(argv.get(2), extra)
    }

    # Default: compile directly.
    src_path = first
    output = "a.out"
    emit_llvm = False
    emit_obj = False
    shared_link = False
    link_args = ""
    opt_level = 2
    debug_info = False
    exports_path = ""
    i = 2
    while i < argv.len() {
        if str_eq(argv.get(i), "-o") and i + 1 < argv.len() {
            output = argv.get(i + 1)
            i = i + 2
            continue
        }
        if str_eq(argv.get(i), "--emit-llvm") {
            emit_llvm = True
        }
        if str_eq(argv.get(i), "--emit-object") {
            emit_obj = True
        }
        if str_eq(argv.get(i), "--shared") {
            shared_link = True
        }
        if str_eq(argv.get(i), "--link-args") and i + 1 < argv.len() {
            link_args = argv.get(i + 1)
            i = i + 2
            continue
        }
        if str_eq(argv.get(i), "--emit-exports") and i + 1 < argv.len() {
            exports_path = argv.get(i + 1)
            i = i + 2
            continue
        }
        if str_eq(argv.get(i), "-O") or str_eq(argv.get(i), "-O2") {
            opt_level = 2
            i = i + 1
            continue
        }
        if str_eq(argv.get(i), "-O0") {
            opt_level = 0
            i = i + 1
            continue
        }
        if str_eq(argv.get(i), "-g") {
            debug_info = True
            i = i + 1
            continue
        }
        i = i + 1
    }
    return compile_and_link(src_path, output, emit_llvm, link_args, opt_level,
                            debug_info, emit_obj, shared_link, exports_path)
}