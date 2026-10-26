# RGC compiler: `rgc --emit-exports` — function metadata for binding generators
#
# A binding generator (pyrgc) must not re-derive signatures by scanning source text: the scanner
# and the type checker drift apart silently. The compiler already holds the checked AST, so it
# publishes every entry-file function's signature plus the one fact a C shim cannot recover on
# its own — whether a returned `str` buffer was freshly allocated and may therefore be freed.
#
# RGC strings are plain libc buffers, and a returned pointer may be a static string literal, a
# parameter's own buffer, or a fresh allocation; freeing the first two corrupts the heap. So
# `owned` is concluded only from `+` on a str-typed expression, which always lowers to
# irg_string_concat (malloc + copy). RGC has no operator overloading, so in a str context that
# is the only meaning `+` can have. Every other shape stays `unknown` and must not be freed.

import util
import ast

# Escape and quote a string as a JSON value. Identifiers and paths need no control-character
# escaping, but doing it here keeps the output valid for any input the compiler is fed.
def json_escape(s: str) -> str {
    out = "\""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 34 {
            out = out + "\\\""
        } elif c == 92 {
            out = out + "\\\\"
        } elif c == 10 {
            out = out + "\\n"
        } elif c == 13 {
            out = out + "\\r"
        } elif c == 9 {
            out = out + "\\t"
        } elif c < 32 {
            out = out + "\\u00"
            if c < 16 {
                out = out + "0"
            }
            out = out + to_string(c)
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out + "\""
}

# Render a type annotation back to source text: `int`, `List[int]`, `Map[str,int]`, `@var Point`.
# An empty name means "no annotation", which is `None` in return position.
public def exports_type_text(t: TypeExpr) -> str {
    inner = t.name
    if inner.len() == 0 {
        inner = "None"
    }
    if t.args.len() > 0 {
        inner = inner + "["
        i = 0
        while i < t.args.len() {
            if i > 0 {
                inner = inner + ","
            }
            inner = inner + exports_type_text(t.args.get(i))
            i = i + 1
        }
        inner = inner + "]"
    }
    if t.is_mut_borrow {
        return "@var " + inner
    }
    if t.is_borrow {
        return "@" + inner
    }
    return inner
}

# ---------- str return ownership ----------

# State of the walk over one function body.
public class StrOwnership {
    params: List[str]       # parameter names
    locals: Map[str, str]   # local name -> ownership class established so far
    returns: List[str]      # ownership class of every return path reached
}

public def make_str_ownership() -> StrOwnership {
    c = StrOwnership()
    c.params = List[str]()
    c.locals = Map[str, str]()
    c.returns = List[str]()
    return c
}

# Combine two classes. Any disagreement means the caller cannot tell which buffer it holds, so
# nothing may be freed. An empty class is "nothing seen yet" and never disagrees.
def own_merge(a: str, b: str) -> str {
    if a.len() == 0 {
        return b
    }
    if b.len() == 0 {
        return a
    }
    if str_eq(a, b) {
        return a
    }
    return "unknown"
}

# Record a binding. Reassignment merges instead of replacing because the two assignments may sit
# in different branches: `if c { m = a } else { m = a + "x" }` then `return m` must not look owned.
def own_bind(c: @var StrOwnership, name: str, cls: str) {
    if c.locals.contains(name) {
        c.locals.put(name, own_merge(c.locals.get(name), cls))
    } else {
        c.locals.put(name, cls)
    }
}

# Ownership class of an expression appearing in return position.
def own_class(c: @var StrOwnership, e: Expr) -> str {
    if e.kind == ExprStringLit() {
        return "static"
    }
    if e.kind == ExprBinary() and str_eq(e.op, "+") {
        return "owned"
    }
    if e.kind == ExprVar() {
        if c.locals.contains(e.name) {
            return c.locals.get(e.name)
        }
        if c.params.contains(e.name) {
            return "borrowed"
        }
        return "unknown"
    }
    if e.kind == ExprBlock() {
        own_stmts(c, e.stmts)
        if e.result.len() > 0 {
            return own_class(c, e.result.get(0))
        }
        # A block whose statements end in `return` produces no value of its own, so it
        # contributes no class instead of dragging the enclosing expression to unknown.
        return ""
    }
    if e.kind == ExprIf() {
        # An if without else has no value on one path; nothing can be concluded.
        if e.then_block.len() == 0 or e.else_block.len() == 0 {
            return "unknown"
        }
        t = own_class(c, e.then_block.get(0))
        f = own_class(c, e.else_block.get(0))
        return own_merge(t, f)
    }
    if e.kind == ExprMatch() {
        if e.arms.len() == 0 {
            return "unknown"
        }
        r = ""
        i = 0
        while i < e.arms.len() {
            r = own_merge(r, own_class(c, e.arms.get(i).body))
            i = i + 1
        }
        return r
    }
    return "unknown"
}

# Record the local bindings and the nested returns inside an expression statement.
def own_expr_walk(c: @var StrOwnership, e: Expr) {
    if e.kind == ExprAssign() {
        # Member assignment writes into an object, not into a local binding.
        if e.target.len() > 0 or e.value.len() == 0 or e.name.len() == 0 {
            return
        }
        own_bind(c, e.name, own_class(c, e.value.get(0)))
        return
    }
    if e.kind == ExprBlock() {
        own_stmts(c, e.stmts)
        if e.result.len() > 0 {
            own_expr_walk(c, e.result.get(0))
        }
        return
    }
    if e.kind == ExprIf() {
        if e.then_block.len() > 0 {
            own_expr_walk(c, e.then_block.get(0))
        }
        if e.else_block.len() > 0 {
            own_expr_walk(c, e.else_block.get(0))
        }
        return
    }
    if e.kind == ExprMatch() {
        i = 0
        while i < e.arms.len() {
            own_expr_walk(c, e.arms.get(i).body)
            i = i + 1
        }
    }
}

def own_stmt(c: @var StrOwnership, st: Stmt) {
    if st.kind == StmtReturn() {
        c.returns.push(own_class(c, st.value))
        return
    }
    if st.kind == StmtExpr() {
        own_expr_walk(c, st.expr)
        return
    }
    if st.kind == StmtFor() or st.kind == StmtWhile() {
        own_stmts(c, st.body)
    }
}

def own_stmts(c: @var StrOwnership, body: List[Stmt]) {
    i = 0
    while i < body.len() {
        own_stmt(c, body.get(i))
        i = i + 1
    }
}

# Ownership class of a str-returning function: the merge of all its return paths.
public def exports_str_ownership(f: Stmt) -> str {
    c = make_str_ownership()
    i = 0
    while i < f.params.len() {
        c.params.push(f.params.get(i).name)
        i = i + 1
    }
    # Mirror irgen: only a top-level `return` suppresses the trailing-expression return value, so
    # a return nested in an `if` still leaves the trailing expression as a real return path.
    has_return = False
    i = 0
    while i < f.body.len() {
        if f.body.get(i).kind == StmtReturn() {
            has_return = True
        }
        i = i + 1
    }
    own_stmts(c, f.body)
    last_idx = f.body.len() - 1
    if last_idx >= 0 and not has_return {
        last = f.body.get(last_idx)
        if last.kind == StmtExpr() {
            c.returns.push(own_class(c, last.expr))
        }
    }
    r = ""
    i = 0
    while i < c.returns.len() {
        r = own_merge(r, c.returns.get(i))
        i = i + 1
    }
    if r.len() == 0 {
        return "unknown"
    }
    return r
}

# ---------- rendering ----------

def exports_render_fn(f: Stmt) -> str {
    out = "{\"name\": " + json_escape(f.name) + ", "
    if f.is_public {
        out = out + "\"public\": true, "
    } else {
        out = out + "\"public\": false, "
    }
    # `export def` — the only functions a binding generator may wrap. The compiler owns this
    # marker so the generator never has to re-derive it by scanning source text.
    if f.is_export {
        out = out + "\"export\": true, "
    } else {
        out = out + "\"export\": false, "
    }
    out = out + "\"params\": ["
    i = 0
    while i < f.params.len() {
        if i > 0 {
            out = out + ", "
        }
        p = f.params.get(i)
        out = out + "{\"name\": " + json_escape(p.name) +
              ", \"type\": " + json_escape(exports_type_text(p.type)) + "}"
        i = i + 1
    }
    out = out + "], "
    ret = exports_type_text(f.ret_type)
    out = out + "\"ret\": " + json_escape(ret) + ", "
    own = ""
    if str_eq(ret, "str") {
        own = exports_str_ownership(f)
    }
    return out + "\"str_ret\": " + json_escape(own) + "}"
}

# JSON metadata for the functions declared in the entry file; imported modules are excluded
# because a binding generator can only export the compilation unit's own symbols.
public def exports_render(stmts: @List[Stmt], src_path: str) -> str {
    out = "{\n  \"format\": 2,\n  \"source\": " + json_escape(src_path) + ",\n  \"functions\": ["
    any_fn = False
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtFnDef() and st.module_name.len() == 0 and not st.is_extern {
            if any_fn {
                out = out + ","
            }
            any_fn = True
            out = out + "\n    " + exports_render_fn(st)
        }
        i = i + 1
    }
    if any_fn {
        out = out + "\n  "
    }
    return out + "]\n}\n"
}

# Write the metadata next to the compilation; returns 0 on success.
public def exports_emit(path: str, stmts: @List[Stmt], src_path: str) -> int {
    wr = write_file(path, exports_render(stmts, src_path))
    if wr.is_err() {
        match wr {
            case Ok(n) => None
            case Err(msg) => write_stderr("error: cannot write " + path + ": " + msg + "\n")
        }
        return 1
    }
    return 0
}
