# RGC compiler: rgc fmt — source formatter
#
# Token-level formatting: the line structure of the lexical stream is preserved
# (no joining, no wrapping, no statement moves); only three things are normalized:
#   1. Indentation — 4 spaces, by brace depth (the `}` in `} else {` drops one level).
#   2. Spaces — normalized spacing around operators, commas, colons, brackets, etc.
#   3. Blank lines — runs of blank lines fold to one; line and block comments are kept verbatim.
#
# Semantic equivalence: RGC syntax is insensitive to newlines, and formatting only
# adjusts whitespace between tokens, so the output parses identically to the input.

import util
import token
import lexer
import diag

# Whether a TokenKind is a "value end" (a following `-` is a binary minus).
public def fmt_is_value_end(k: TokenKind) -> bool {
    if k == TokIdent() { return True }
    if k == TokIntLit() { return True }
    if k == TokFloatLit() { return True }
    if k == TokStringLit() { return True }
    if k == TokRParen() { return True }
    if k == TokRBracket() { return True }
    if k == TokTrue() { return True }
    if k == TokFalse() { return True }
    if k == TokNone() { return True }
    return False
}

# Whether adjacent tokens on the same line need a space (only called within one line).
# minus_unary means the previous token is a unary minus (its operand sticks to it).
public def fmt_need_space(p: @Token, t: @Token, minus_unary: bool) -> bool {
    pk = p.kind
    tk = t.kind
    # On the t side: punctuation that takes no space before it.
    if tk == TokComma() { return False }
    if tk == TokSemi() { return False }
    if tk == TokColon() { return False }
    if tk == TokRParen() { return False }
    if tk == TokRBracket() { return False }
    if tk == TokDot() { return False }
    if tk == TokQuestion() { return False }
    if tk == TokRBrace() and pk == TokLBrace() { return False }     # `{}`
    if tk == TokLParen() and (pk == TokIdent() or pk == TokRBracket()) { return False }
    if tk == TokLBracket() and (pk == TokIdent() or pk == TokRBracket()) { return False }
    # On the p side: punctuation that takes no space after it.
    if pk == TokLParen() { return False }
    if pk == TokLBracket() { return False }
    if pk == TokDot() { return False }
    if pk == TokAt() { return False }
    # A unary minus sticks to its operand: `-42`, `(x, -y)`, `x[-1]`.
    if pk == TokMinus() and minus_unary { return False }
    # Everything else (comments, operators, keywords) gets a space.
    return True
}

# Re-escape string literals (the lexer stores decoded text; writing it back verbatim would corrupt the source).
public def fmt_escape_string(s: str) -> str {
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
        } elif c == 9 {
            out = out + "\\t"
        } elif c == 13 {
            out = out + "\\r"
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out + "\""
}

# Canonical text of a token (strings re-escaped; everything else verbatim).
public def fmt_token_text(t: @Token) -> str {
    if t.kind == TokStringLit() {
        return fmt_escape_string(t.text)
    }
    return t.text
}

# Number of lines occupied by a token's text (multi-line block comments > 1; otherwise 1).
public def fmt_token_span_lines(t: @Token) -> int {
    n = 1
    i = 0
    while i < t.text.len() {
        if t.text.char_at(i) == 10 {
            n = n + 1
        }
        i = i + 1
    }
    return n
}

# Format source text and return the formatted result (always ends with a single newline).
# On lexical failure, structured diagnostics are written into errs (file left empty for the caller to attribute) and the source is returned unchanged.
public def fmt_source(src: str, errs: @var List[DiagItem]) -> str {
    lx = make_lexer(src)
    lx.keep_comments = True
    toks = lexer_tokenize(@var lx)
    if not lx.ok {
        it = DiagItem()
        it.line = lx.err_line
        it.col = lx.err_col
        it.msg = lx.err_msg
        it.file = ""
        errs.push(it)
        return src
    }

    lines = List[str]()
    cur = ""
    line_open = False
    ind = ""
    depth = 0
    prev = make_token(TokEof(), "", 0, 0)
    have_prev = False
    minus_unary = False

    i = 0
    while i < toks.len() {
        t = toks.get(i)
        if t.kind == TokEof() {
            break
        }
        first_on_line = not have_prev or t.line > prev.line
        if first_on_line {
            if line_open {
                lines.push(cur)
            }
            line_open = False
            # Blank-line folding: keep one blank line when the gap to the previous token is >= 1;
            # no blank line before a closing `}`.
            if have_prev {
                prev_end = prev.line + fmt_token_span_lines(@prev) - 1
                gap = t.line - prev_end - 1
                if gap > 0 and t.kind != TokRBrace() {
                    lines.push("")
                }
            }
            if t.kind == TokRBrace() {
                depth = depth - 1
            }
            ind = ""
            n = 0
            while n < depth {
                ind = ind + "    "
                n = n + 1
            }
            cur = ind
        }
        if not first_on_line and cur.len() > 0 and fmt_need_space(@prev, @t, minus_unary) {
            cur = cur + " "
        }
        # Unary minus detection: the previous token is not a "value end" (`= -42`, `(x, -y)`, `x[-1]`).
        if t.kind == TokMinus() {
            minus_unary = not fmt_is_value_end(prev.kind)
        } else {
            minus_unary = False
        }
        # Multi-line block comment: first line joins the current line; subsequent lines are re-indented to the current indent (original indentation removed).
        if t.kind == TokComment() and t.text.contains("\n") {
            parts = t.text.split("\n")
            cur = cur + parts.get(0)
            lines.push(cur)
            line_open = False
            j = 1
            while j < parts.len() {
                seg = trim(parts.get(j))
                if seg.len() > 0 {
                    lines.push(ind + seg)
                } else {
                    lines.push("")
                }
                j = j + 1
            }
            cur = ind
        } else {
            cur = cur + fmt_token_text(@t)
            line_open = True
            pass
        }
        if t.kind == TokLBrace() {
            depth = depth + 1
        }
        if t.kind == TokRBrace() and not first_on_line {
            depth = depth - 1
        }
        prev = t
        have_prev = True
        i = i + 1
    }
    if line_open {
        lines.push(cur)
    }
    return "\n".join(lines) + "\n"
}

# fmt subcommand entry point: format files in batch.
# With check_only, only report without writing back; returns 1 if any file would change (for CI).
# When the path is a directory, expand to all *.rg files inside (RGC has no readdir; uses shell ls, same approach as rack).
public def fmt_expand_path(p: str, out: @var List[str]) {
    q = "'" + p + "'"
    if system("test -d " + q) == 0 {
        tmp = "/tmp/.rgc_fmt_ls.txt"
        rc = system("ls " + q + "/*.rg > " + tmp + " 2>/dev/null")
        if rc == 0 {
            for ln in read_file_or(tmp).split("\n") {
                t = trim(ln)
                if t.len() > 0 {
                    out.push(t)
                }
            }
        }
        return
    }
    out.push(p)
}

public def fmt_files(paths: List[str], check_only: bool) -> int {
    files = List[str]()
    i = 0
    while i < paths.len() {
        fmt_expand_path(paths.get(i), @var files)
        i = i + 1
    }
    rc = 0
    i = 0
    while i < files.len() {
        p = files.get(i)
        r = read_file(p)
        if r.is_err() {
            write_stderr("error: cannot read " + p + "\n")
            rc = 1
            i = i + 1
            continue
        }
        src = r.unwrap()
        errs = List[DiagItem]()
        out = fmt_source(src, @var errs)
        if errs.len() > 0 {
            write_stderr(diag_render(p, src, @errs))
            rc = 1
            i = i + 1
            continue
        }
        if not str_eq(out, src) {
            if check_only {
                print(p + ": would reformat")
                rc = 1
                pass
            } else {
                wr = write_file(p, out)
                if wr.is_err() {
                    rc = 1
                    match wr {
                        case Ok(n) => None
                        case Err(msg) => print("error: cannot write " + p + ": " + msg)
                    }
                    pass
                } else {
                    print("formatted " + p)
                    pass
                }
                pass
            }
        }
        i = i + 1
    }
    return rc
}
