# RGC compiler: diagnostic collection and rustc-style rendering
#
# Diagnostic rendering (v0.0.5 unified error codes, Rust-style detail):
#   error[E0XXX]: <message>
#      --> <source>:<line>:<col>
#       |
#     n | <source line>
#       |    ^^^ <caret>
#       |
#     m | <secondary span line>
#       |    --- <label>
#       |
#       = note: <note>
#     help: <help>
#
# Every diagnostic carries a stable error code (see devdoc/RGC-0.0.5-ERRORCODES.md).
# Diagnostics may also carry an optional `help` line, a `note` line, and
# secondary spans (`subs`) that point at related locations (move origins,
# conflicting borrows, declared definitions, etc.) like rustc.
# Entries also carry a file attribute: empty = the entry file; otherwise it is a
# module name (resolved by the loader before rendering) or a path directly.
# Multi-file rendering is handled by diag_render_multi.

import util

# A secondary source span attached to a diagnostic (e.g. "value moved here").
public class DiagSpan {
    line: int
    col: int
    len: int
    label: str
    file: str
}

public class DiagItem {
    line: int
    col: int
    msg: str
    code: str
    file: str
    help: str
    note: str
    subs: List[DiagSpan]
}

public def make_diag_items() -> List[DiagItem] {
    return List[DiagItem]()
}

public def diag_push(items: @var List[DiagItem], code: str, line: int, col: int, msg: str) {
    it = DiagItem()
    it.line = line
    it.col = col
    it.msg = msg
    it.code = code
    it.file = ""
    it.help = ""
    it.note = ""
    it.subs = List[DiagSpan]()
    items.push(it)
}

public def make_diag_span(line: int, col: int, len: int, label: str) -> DiagSpan {
    sp = DiagSpan()
    sp.line = line
    sp.col = col
    sp.len = len
    sp.label = label
    sp.file = ""
    return sp
}

public def diag_repeat(ch: str, n: int) -> str {
    out = ""
    i = 0
    while i < n {
        out = out + ch
        i = i + 1
    }
    return out
}

public def diag_is_digit(c: int) -> bool {
    return c >= 48 and c <= 57
}

public def diag_is_alpha(c: int) -> bool {
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
}

public def diag_is_ident(c: int) -> bool {
    return diag_is_alpha(c) or diag_is_digit(c) or c == 95
}

public def diag_lines(source: str) -> List[str] {
    lines = List[str]()
    start = 0
    i = 0
    while i < source.len() {
        if source.char_at(i) == "\n".char_at(0) {
            lines.push(source.slice(start, i))
            start = i + 1
        }
        i = i + 1
    }
    if start < source.len() {
        lines.push(source.slice(start, source.len()))
    }
    if source.len() == 0 or source.char_at(source.len() - 1) == "\n".char_at(0) {
        lines.push("")
    }
    return lines
}

# Caret length: one caret per character, clamped to the line length.
public def diag_caret_len(line: str, spaces: int) -> int {
    if spaces < 0 or spaces >= line.len() {
        return 1
    }
    first = line.char_at(spaces)
    if first == "\"".char_at(0) {
        n = 1
        while spaces + n < line.len() {
            ch = line.char_at(spaces + n)
            if ch == "\\".char_at(0) {
                n = n + 2
            } else {
                n = n + 1
                if ch == "\"".char_at(0) {
                    break
                }
            }
        }
        return n
    }
    if diag_is_ident(first) {
        is_digit = diag_is_digit(first)
        n = 0
        while spaces + n < line.len() {
            ch = line.char_at(spaces + n)
            if diag_is_ident(ch) or (is_digit and ch == ".".char_at(0)) {
                n = n + 1
            } else {
                break
            }
        }
        if n == 0 {
            n = 1
        }
        return n
    }
    return 1
}

# Render a single diagnostic (including a trailing blank line). width is the line-number column width (aligned by the largest line number when rendering many).
# When line < 1 there is no row/column to show; only the file is labeled.
# Rust-style detail: primary span (^) plus secondary spans (-) with labels,
# followed by an optional `= note:` line and a `help:` line.
public def diag_render_one(source_name: str, source: str, it: @DiagItem,
                           width: int) -> str {
    lines = diag_lines(source)
    if width < 2 {
        width = 2
    }

    # Unified error code: error[E0XXX]: msg; legacy entries with an empty code
    # keep the original rustc-style "error: msg" header.
    if it.code.len() > 0 {
        out = "error[" + it.code + "]: " + it.msg + "\n"
    } else {
        out = "error: " + it.msg + "\n"
    }
    if it.line < 1 {
        out = out + diag_repeat(" ", width) + "--> " + source_name + "\n"
        return out + "\n"
    }
    out = out + diag_repeat(" ", width) + "--> " + source_name + ":" +
          to_string(it.line) + ":" + to_string(it.col) + "\n"
    out = out + diag_repeat(" ", width + 1) + "|\n"

    # Collect spans: primary + secondary, with resolved source text.
    sp_lines = List[int]()
    sp_cols = List[int]()
    sp_lens = List[int]()
    sp_labels = List[str]()
    sp_srcs = List[str]()
    sp_prim = List[int]()

    sp_lines.push(it.line)
    sp_cols.push(it.col)
    sp_lens.push(1)          # primary caret length is recomputed from the token
    sp_labels.push("")
    sp_srcs.push(source)
    sp_prim.push(1)

    i = 0
    while i < it.subs.len() {
        sp = it.subs.get(i)
        ssrc = source
        if sp.file.len() > 0 and not str_eq(sp.file, source_name) {
            r = read_file(sp.file)
            if r.is_ok() {
                ssrc = r.unwrap()
            }
        }
        sp_lines.push(sp.line)
        sp_cols.push(sp.col)
        sp_lens.push(sp.len)
        sp_labels.push(sp.label)
        sp_srcs.push(ssrc)
        sp_prim.push(0)
        i = i + 1
    }

    # Stable insertion sort by line (small n; rustc renders spans in source order).
    # Note: each parallel list needs its own typed temporary (RGC variables are
    # statically typed on first assignment; reusing one `t` for int and str
    # breaks IR generation).
    n = sp_lines.len()
    a = 1
    while a < n {
        b = a
        while b > 0 and sp_lines.get(b) < sp_lines.get(b - 1) {
            ti = sp_lines.get(b)
            sp_lines.set(b, sp_lines.get(b - 1))
            sp_lines.set(b - 1, ti)
            ti = sp_cols.get(b)
            sp_cols.set(b, sp_cols.get(b - 1))
            sp_cols.set(b - 1, ti)
            ti = sp_lens.get(b)
            sp_lens.set(b, sp_lens.get(b - 1))
            sp_lens.set(b - 1, ti)
            ts = sp_labels.get(b)
            sp_labels.set(b, sp_labels.get(b - 1))
            sp_labels.set(b - 1, ts)
            ts = sp_srcs.get(b)
            sp_srcs.set(b, sp_srcs.get(b - 1))
            sp_srcs.set(b - 1, ts)
            ti = sp_prim.get(b)
            sp_prim.set(b, sp_prim.get(b - 1))
            sp_prim.set(b - 1, ti)
            b = b - 1
        }
        a = a + 1
    }

    prev_line = -1
    k = 0
    while k < n {
        ln = sp_lines.get(k)
        slines = diag_lines(sp_srcs.get(k))
        if ln >= 1 and ln <= slines.len() {
            if prev_line >= 0 and ln > prev_line + 1 {
                out = out + diag_repeat(" ", width + 1) + "|\n"
            }
            # Spans on the same source line share one source line (rustc style);
            # each span gets its own underline row (`^` for primary, `-` for secondary).
            group_src = sp_srcs.get(k)
            line_num = to_string(ln)
            out = out + diag_repeat(" ", width - line_num.len()) + line_num + " | " +
                  slines.get(ln - 1) + "\n"
            while k < n and sp_lines.get(k) == ln and str_eq(sp_srcs.get(k), group_src) {
                out = out + diag_repeat(" ", width + 1) + "| "
                spaces = sp_cols.get(k) - 1
                if spaces < 0 {
                    spaces = 0
                }
                out = out + diag_repeat(" ", spaces)
                if sp_prim.get(k) == 1 {
                    clen = diag_caret_len(slines.get(ln - 1), spaces)
                    out = out + diag_repeat("^", clen)
                } else {
                    l2 = sp_lens.get(k)
                    if l2 < 1 {
                        l2 = 1
                    }
                    out = out + diag_repeat("-", l2)
                }
                if sp_labels.get(k).len() > 0 {
                    out = out + " " + sp_labels.get(k)
                }
                out = out + "\n"
                k = k + 1
            }
            prev_line = ln
            continue
        }
        k = k + 1
    }

    # Note and help lines (rustc style).
    if it.note.len() > 0 {
        out = out + diag_repeat(" ", width + 1) + "|\n"
        out = out + "= note: " + it.note + "\n"
    }
    if it.help.len() > 0 {
        out = out + "help: " + it.help + "\n"
    }
    return out + "\n"
}

# rustc-style trailing hint: for each unique error code, suggest `rgc explain`.
# Returns "" when no diagnostic carries a code (legacy path).
def diag_explain_hint(items: @List[DiagItem]) -> str {
    seen = List[str]()
    out = ""
    i = 0
    while i < items.len() {
        it = items.get(i)
        code = it.code
        if code.len() > 0 {
            j = 0
            found = False
            while j < seen.len() {
                if str_eq(seen.get(j), code) {
                    found = True
                }
                j = j + 1
            }
            if not found {
                seen.push(code)
                out = out + "For more information about this error, try `rgc explain " +
                      code + "`.\n"
            }
        }
        i = i + 1
    }
    return out
}

# Line-number column width for a diagnostic list (for alignment).
public def diag_width(items: @List[DiagItem]) -> int {
    max_line = 0
    i = 0
    while i < items.len() {
        it = items.get(i)
        if it.line > max_line {
            max_line = it.line
        }
        i = i + 1
    }
    width = to_string(max_line).len()
    if width < 2 {
        width = 2
    }
    return width
}

# Batch render for a single source (kept as the legacy interface; use diag_render_multi across files).
public def diag_render(source_name: str, source: str,
                       items: @List[DiagItem]) -> str {
    width = diag_width(items)
    out = ""
    i = 0
    while i < items.len() {
        cur = items.get(i)
        out = out + diag_render_one(source_name, source, @cur, width)
        i = i + 1
    }
    return out + diag_explain_hint(items)
}

# Multi-file diagnostic rendering: when file is empty or equals the entry name, render with the entry source;
# otherwise treat file as a path and read the source from disk (with caching). Duplicate entries with the same file/position/message
# are rendered once (cascade errors are deduplicated).
public def diag_render_multi(entry_name: str, entry_src: str,
                             items: @List[DiagItem]) -> str {
    width = diag_width(items)
    out = ""
    paths = List[str]()
    srcs = List[str]()
    i = 0
    while i < items.len() {
        it = items.get(i)
        dup = False
        j = 0
        while j < i {
            prev = items.get(j)
            if prev.line == it.line and prev.col == it.col and
               str_eq(prev.msg, it.msg) and str_eq(prev.file, it.file) {
                dup = True
            }
            j = j + 1
        }
        if dup {
            i = i + 1
            continue
        }
        name = entry_name
        src = entry_src
        if it.file.len() > 0 and not str_eq(it.file, entry_name) {
            k = 0
            found = False
            while k < paths.len() {
                if str_eq(paths.get(k), it.file) {
                    name = it.file
                    src = srcs.get(k)
                    found = True
                }
                k = k + 1
            }
            if not found {
                r = read_file(it.file)
                if r.is_ok() {
                    name = it.file
                    src = r.unwrap()
                    paths.push(it.file)
                    srcs.push(src)
                }
            }
        }
        # Resolve secondary-span file attributes the same way (module name -> path),
        # so diag_render_one can read them from disk when they differ from the parent.
        si = 0
        while si < it.subs.len() {
            sp = it.subs.get(si)
            if sp.file.len() > 0 and not str_eq(sp.file, entry_name) and
               not str_eq(sp.file, name) {
                k = 0
                sfound = False
                while k < paths.len() {
                    if str_eq(paths.get(k), sp.file) {
                        sp.file = paths.get(k)
                        sfound = True
                    }
                    k = k + 1
                }
                if not sfound {
                    r2 = read_file(sp.file)
                    if r2.is_ok() {
                        sp.file = sp.file
                        paths.push(sp.file)
                        srcs.push(r2.unwrap())
                        sfound = True
                    }
                }
                if not sfound {
                    sp.file = name
                }
            }
            it.subs.set(si, sp)
            si = si + 1
        }
        out = out + diag_render_one(name, src, @it, width)
        i = i + 1
    }
    return out + diag_explain_hint(items)
}
