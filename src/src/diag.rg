# RGC compiler: diagnostic collection and rustc-style rendering
#
# Diagnostic rendering:
#   error: <message>
#      --> <source>:<line>:<col>
#       |
#     n | <source line>
#       |    ^^^
#
# Diagnostic entries carry a file attribute: empty = the entry file; otherwise
# it is a module name (resolved by the loader before rendering) or a path
# directly. Multi-file rendering is handled by diag_render_multi.

import util

public class DiagItem {
    line: int
    col: int
    msg: str
    file: str
}

public def make_diag_items() -> List[DiagItem] {
    return List[DiagItem]()
}

public def diag_push(items: @var List[DiagItem], line: int, col: int, msg: str) {
    it = DiagItem()
    it.line = line
    it.col = col
    it.msg = msg
    it.file = ""
    items.push(it)
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
public def diag_render_one(source_name: str, source: str, it: @DiagItem,
                           width: int) -> str {
    lines = diag_lines(source)
    if width < 2 {
        width = 2
    }

    out = "error: " + it.msg + "\n"
    if it.line >= 1 {
        out = out + diag_repeat(" ", width) + "--> " + source_name + ":" +
              to_string(it.line) + ":" + to_string(it.col) + "\n"
        if it.line <= lines.len() {
            out = out + diag_repeat(" ", width + 1) + "|\n"
            line_num = to_string(it.line)
            out = out + diag_repeat(" ", width - line_num.len()) + line_num + " | " +
                  lines.get(it.line - 1) + "\n"
            out = out + diag_repeat(" ", width + 1) + "| "
            spaces = it.col - 1
            if spaces < 0 {
                spaces = 0
            }
            out = out + diag_repeat(" ", spaces)
            out = out + diag_repeat("^", diag_caret_len(lines.get(it.line - 1), spaces)) + "\n"
        }
    } else {
        out = out + diag_repeat(" ", width) + "--> " + source_name + "\n"
    }
    return out + "\n"
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
    return out
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
        out = out + diag_render_one(name, src, @it, width)
        i = i + 1
    }
    return out
}
