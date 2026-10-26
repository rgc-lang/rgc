# Module loading.
#
# ModuleResolver with standard-library search:
#   - the entry file's directory <name>.rg takes priority (project modules can shadow the stdlib)
#   - $RGC_STD (colon-separated)
#   - lib/ and lib/rgc/ relative to the compiler executable
#   - /usr/local/lib/rgc, /usr/lib/rgc
#   - io/time/random/os: built-in virtual modules, considered loaded even without a source file
#   - DFS merges top-level statements, marking module_name / module_is_std
#   - canonical path cache; cyclic imports are allowed (like Rust; Sema's global resolution is the fallback)
#   - directory modules: hierarchical paths like net/tcp plus the name/mod.rg convention
#   - from m import a, b as c: statements are kept in the merged AST and Sema builds the import scope

import util
import ast
import lexer
import parser
import diag

public class ModuleFile {
    path: str
    src: str
    is_std: bool
    found: bool
}

public class ModuleLoader {
    dir: str
    entry_path: str                     # entry file path (attributed to entry diagnostics)
    search_dirs: List[str]
    cache: Map[str, int]
    loading: List[str]
    merged: List[Stmt]
    ok: bool
    error_msg: str                      # rendered diagnostic text (printed directly by the CLI)
    err_items: List[DiagItem]           # structured errors (used by LSP)
    module_paths: Map[str, str]         # canonical module name -> file path
}

# ---------- compiler binary path / environment ----------
# Only existing builtins are used to keep this file portable across compiler versions.
# Note: files under /proc have ftell == 0 and cannot be read with read_file; use a shell redirect instead.

def sh_output(cmd: str, path: str) -> str {
    tmp = path
    if is_windows() {
        tmp = ".rgc-sh-output.tmp"
        system(cmd + " > " + tmp)
    } else {
        system(cmd + " > " + path + " 2>/dev/null")
    }
    v = trim(read_file_or(tmp))
    remove_file(tmp)
    return v
}

def is_windows() -> bool {
    # The OS environment variable is authoritative (bare `rgc` from PATH has no path separator to inspect);
    # the argv[0] shape remains a fallback for environments that scrub OS.
    if host_is_windows() {
        return True
    }
    av = args()
    if av.len() == 0 {
        return False
    }
    p = av.get(0)
    if windows_path(p) {
        return True
    }
    return str_find(p, "\\") >= 0
}

def env_value(name: str) -> str {
    if is_windows() {
        tmp = ".rgc-env.tmp"
        system("echo %" + name + "% > " + tmp)
        v = trim(read_file_or(tmp))
        remove_file(tmp)
        if v == "%" + name + "%" {
            return ""
        }
        return v
    }
    return sh_output("printenv " + name, "/tmp/.rgc-env-" + name)
}

def sh_quote(s: str) -> str {
    return "\"" + s + "\""
}

def windows_path(p: str) -> bool {
    if p.len() >= 2 and p.char_at(1) == 58 {
        return True
    }
    if p.len() >= 2 and p.char_at(0) == 92 and p.char_at(1) == 92 {
        return True
    }
    return False
}

def slash_path(p: str) -> str {
    out = ""
    i = 0
    while i < p.len() {
        if p.char_at(i) == 92 {
            out = out + "/"
        } else {
            out = out + p.slice(i, i + 1)
        }
        i = i + 1
    }
    return out
}

def compiler_exe() -> str {
    av = args()
    p = ""
    if av.len() > 0 {
        p = av.get(0)
    }
    if windows_path(p) {
        return slash_path(p)
    }
    q = sh_quote(p)
    if is_windows() {
        if str_find(p, "\\") >= 0 {
            return slash_path(p)
        }
        if str_find(p, "/") >= 0 {
            # MSYS/Git Bash may hand over a POSIX-style absolute path; convert it when possible.
            if p.startswith("/") {
                w = sh_output("cygpath -w " + q, ".rgc-exe-path.tmp")
                line = first_line(w)
                if line.len() > 0 {
                    return slash_path(line)
                }
            }
            return slash_path(p)
        }
        # Bare command name: `where` performs the PATH search; take its first match.
        r = sh_output("where " + q, ".rgc-exe-path.tmp")
        line = first_line(r)
        if line.len() > 0 {
            return slash_path(line)
        }
        return p
    }
    if str_find(p, "/") >= 0 {
        # readlink -f resolves symlinks on Linux; BSD readlink rejects -f, so keep p on failure.
        r = sh_output("readlink -f " + q, "/tmp/.rgc-exe-path")
        if r.len() > 0 {
            return r
        }
        return p
    }
    # Bare command name: resolve through the shell's PATH search first (macOS has no /proc),
    # then fall back to /proc/<ppid>/exe on Linux.
    r = sh_output("command -v " + q, "/tmp/.rgc-exe-path")
    if r.len() > 0 {
        return r
    }
    return sh_output("readlink /proc/$PPID/exe", "/tmp/.rgc-exe-path")
}

def parent_dir(p: str) -> str {
    i = str_rfind(p, "/")
    if i < 0 {
        return ""
    }
    if i == 0 {
        return "/"
    }
    return p.slice(0, i)
}

def add_search_dir(dirs: @var List[str], d: str) {
    if d.len() == 0 {
        return
    }
    if dirs.contains(d) {
        return
    }
    dirs.push(d)
}

def stdlib_dirs() -> List[str] {
    dirs = List[str]()
    std_env = env_value("RGC_STD")
    if std_env.len() > 0 {
        sep = ":"
        if is_windows() {
            sep = ";"
        }
        parts = std_env.split(sep)
        i = 0
        while i < parts.len() {
            add_search_dir(@var dirs, trim(parts.get(i)))
            i = i + 1
        }
    }
    exe = compiler_exe()
    d = ""
    if str_find(exe, "/") >= 0 {
        d = parent_dir(exe)
    }
    k = 0
    while k < 4 and d.len() > 0 {
        add_search_dir(@var dirs, d + "/lib")
        add_search_dir(@var dirs, d + "/lib/rgc")
        nd = parent_dir(d)
        if str_eq(nd, d) {
            d = ""
        } else {
            d = nd
        }
        k = k + 1
    }
    if not is_windows() {
        add_search_dir(@var dirs, "/usr/local/lib/rgc")
        add_search_dir(@var dirs, "/usr/lib/rgc")
    }
    return dirs
}

public def make_module_loader(src_path: str) -> ModuleLoader {
    l = ModuleLoader()
    slash = str_rfind(src_path, "/")
    bslash = str_rfind(src_path, "\\")
    if bslash > slash {
        slash = bslash
    }
    if slash >= 0 {
        l.dir = src_path.slice(0, slash)
    } else {
        l.dir = "."
    }
    if is_windows() {
        l.dir = slash_path(l.dir)
    }
    if l.dir.len() == 0 {
        l.dir = "."
    }
    l.entry_path = src_path
    l.search_dirs = stdlib_dirs()
    l.cache = Map[str, int]()
    l.loading = List[str]()
    l.merged = List[Stmt]()
    l.ok = True
    l.error_msg = ""
    l.err_items = List[DiagItem]()
    l.module_paths = Map[str, str]()
    return l
}

# Record a lexical/parse failure: the structured item goes into err_items (LSP),
# and the rendered text goes into error_msg (CLI printing). When line < 1, only the file is labeled.
def loader_fail(l: @var ModuleLoader, path: str, src: str,
                line: int, col: int, msg: str) {
    l.ok = False
    it = DiagItem()
    it.line = line
    it.col = col
    it.msg = msg
    it.file = path
    items = List[DiagItem]()
    items.push(it)
    l.err_items.push(items.get(0))
    l.error_msg = diag_render(path, src, @items)
}

public def module_path(l: @var ModuleLoader, name: str) -> str {
    if str_eq(l.dir, ".") or l.dir.len() == 0 {
        return name + ".rg"
    }
    return l.dir + "/" + name + ".rg"
}

# Look for a module in the entry directory then the standard-library directories; when not found, path is the entry-directory candidate.
# With local_first=False the entry directory is skipped (io only allows the standard-library version, so example files cannot shadow it).
public def find_module(l: @var ModuleLoader, name: str, local_first: bool) -> ModuleFile {
    f = ModuleFile()
    f.path = module_path(l, name)
    f.src = ""
    f.is_std = False
    f.found = False
    if local_first {
        r = read_file(f.path)
        if r.is_ok() {
            f.src = r.unwrap()
            f.found = True
            return f
        }
        # Directory module convention: when name.rg is absent, fall back to name/mod.rg (like Rust's mod.rs).
        mpath = f.path.slice(0, f.path.len() - 3) + "/mod.rg"
        r3 = read_file(mpath)
        if r3.is_ok() {
            f.path = mpath
            f.src = r3.unwrap()
            f.found = True
            return f
        }
    }
    i = 0
    while i < l.search_dirs.len() {
        p = l.search_dirs.get(i) + "/" + name + ".rg"
        r2 = read_file(p)
        if r2.is_ok() {
            f.path = p
            f.src = r2.unwrap()
            f.is_std = True
            f.found = True
            return f
        }
        mpath2 = l.search_dirs.get(i) + "/" + name + "/mod.rg"
        r4 = read_file(mpath2)
        if r4.is_ok() {
            f.path = mpath2
            f.src = r4.unwrap()
            f.is_std = True
            f.found = True
            return f
        }
        i = i + 1
    }
    return f
}

public def loader_is_loading(l: @var ModuleLoader, path: str) -> bool {
    i = 0
    while i < l.loading.len() {
        if str_eq(l.loading.get(i), path) {
            return True
        }
        i = i + 1
    }
    return False
}

public def loader_mark_module(l: @var ModuleLoader, name: str, st: @var Stmt) {
    st.module_name = name
}

# Built-in modules provided directly by the compiler; project files with the same name cannot shadow them.
public def is_virtual_module(name: str) -> bool {
    return str_eq(name, "io") or str_eq(name, "time") or
           str_eq(name, "random") or str_eq(name, "os") or
           str_eq(name, "asyncio")
}

public def loader_load(l: @var ModuleLoader, name: str) {
    if not l.ok {
        return
    }
    mf = find_module(l, name, not is_virtual_module(name))
    if not mf.found {
        # Built-in virtual modules have no source file; their symbols are provided by sema/IR.
        if is_virtual_module(name) {
            return
        }
        l.ok = False
        l.error_msg = "error: cannot read module `" + name + "` at " + mf.path + "\n"
        return
    }
    path = mf.path
    is_std = mf.is_std
    src = mf.src
    if l.cache.contains(path) {
        return
    }
    # Normalize the physical prefix of hierarchical paths (net/tcp -> net$tcp); plain module names are unchanged.
    name = module_canon(name)
    # For diagnostic attribution: module name -> file path.
    l.module_paths.put(name, path)
    if loader_is_loading(l, path) {
        # Cyclic imports are legal (like Rust): symbols are physically isolated and Sema resolves globally;
        # a module being loaded needs no re-entry; its statements join the merged AST once its own load completes.
        return
    }

    lx = make_lexer(src)
    toks = lexer_tokenize(@var lx)
    if not lx.ok {
        loader_fail(l, path, src, lx.err_line, lx.err_col, lx.err_msg)
        return
    }
    p = make_parser(toks)
    stmts = parser_parse_program(@var p)
    if not p.ok {
        loader_fail(l, path, src, p.err_line, p.err_col, p.err_msg)
        return
    }

    l.loading.push(path)
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtImport() {
            loader_load(l, st.import_module)
            if not l.ok {
                return
            }
            # All import statements are kept in the merged AST: from/glob establish import scopes,
            # plain imports record the bound name (last segment of a hierarchical path) -> canonical module name.
            st.module_name = name
            st.module_is_std = is_std
            l.merged.push(st)
        } else {
            loader_mark_module(l, name, @var st)
            st.module_is_std = is_std
            l.merged.push(st)
        }
        i = i + 1
    }
    l.loading.pop()
    l.cache.put(path, 1)
}

# Parse the entry file and merge its imports (entry statements keep module_name empty).
public def loader_load_entry(l: @var ModuleLoader, src: str) -> List[Stmt] {
    lx = make_lexer(src)
    toks = lexer_tokenize(@var lx)
    if not lx.ok {
        loader_fail(l, l.entry_path, src, lx.err_line, lx.err_col, lx.err_msg)
        return List[Stmt]()
    }
    p = make_parser(toks)
    stmts = parser_parse_program(@var p)
    if not p.ok {
        loader_fail(l, l.entry_path, src, p.err_line, p.err_col, p.err_msg)
        return List[Stmt]()
    }
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtImport() {
            loader_load(l, st.import_module)
            if not l.ok {
                return List[Stmt]()
            }
            # The entry file's imports are kept too (empty module_name = entry scope).
            l.merged.push(st)
        } else {
            l.merged.push(st)
        }
        i = i + 1
    }
    return l.merged
}
