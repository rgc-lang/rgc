# RGC compiler: lexer
#
# Scans RGC source into a token list. Characters are accessed with `str.char_at(i)` (byte values).
# Lexeme text is sliced directly from the source via `slice(start, pos)` to avoid byte->char conversions.
# Corresponds to src/lexer/Lexer.cpp in the C++ compiler.

import util
import token
import types
import ast

# Character code constants.
public def char_digit_0() -> int { return "0".char_at(0) }
public def char_digit_9() -> int { return "9".char_at(0) }
public def char_a() -> int { return "a".char_at(0) }
public def char_z() -> int { return "z".char_at(0) }
public def char_A() -> int { return "A".char_at(0) }
public def char_Z() -> int { return "Z".char_at(0) }
public def char_underscore() -> int { return "_".char_at(0) }
public def char_dot() -> int { return ".".char_at(0) }
public def char_quote() -> int { return "\"".char_at(0) }
public def char_hash() -> int { return "#".char_at(0) }
public def char_slash() -> int { return "/".char_at(0) }
public def char_star() -> int { return "*".char_at(0) }
public def char_backslash() -> int { return "\\".char_at(0) }
public def char_n() -> int { return "n".char_at(0) }
public def char_t() -> int { return "t".char_at(0) }
public def char_r() -> int { return "r".char_at(0) }
public def char_e() -> int { return "e".char_at(0) }
public def char_E() -> int { return "E".char_at(0) }
public def char_plus() -> int { return "+".char_at(0) }
public def char_minus() -> int { return "-".char_at(0) }
public def char_newline() -> int { return "\n".char_at(0) }

public def is_digit(c: int) -> bool {
    return c >= char_digit_0() and c <= char_digit_9()
}

public def is_alpha(c: int) -> bool {
    return (c >= char_a() and c <= char_z()) or (c >= char_A() and c <= char_Z())
}

public def is_alnum(c: int) -> bool {
    return is_digit(c) or is_alpha(c) or c == char_underscore()
}

public class Lexer {
    src: str
    pos: int
    line: int
    col: int
    keep_comments: bool
    # Structured lexical errors, rendered uniformly by callers (loader/fmt/analyzer).
    ok: bool
    err_line: int
    err_col: int
    err_msg: str
}

# Construct a lexer.
public def make_lexer(src: str) -> Lexer {
    lx = Lexer()
    lx.src = src
    lx.pos = 0
    lx.line = 1
    lx.col = 1
    lx.keep_comments = False
    lx.ok = True
    lx.err_line = 0
    lx.err_col = 0
    lx.err_msg = ""
    return lx
}

# Byte code of the character at offset lookahead; returns 0 when out of bounds.
public def lexer_peek(lx: @var Lexer, offset: int) -> int {
    if lx.pos + offset < lx.src.len() {
        return lx.src.char_at(lx.pos + offset)
    }
    return 0
}

# Consume one character and return its byte code; returns 0 when out of bounds.
public def lexer_advance(lx: @var Lexer) -> int {
    if lx.pos >= lx.src.len() {
        return 0
    }
    c = lx.src.char_at(lx.pos)
    lx.pos = lx.pos + 1
    if c == char_newline() {
        lx.line = lx.line + 1
        lx.col = 1
    } else {
        lx.col = lx.col + 1
    }
    return c
}

# Skip whitespace and comments (# to end of line, /* */ block comments).
# With keep_comments, comments are left for lexer_tokenize to produce TokComment; only whitespace is skipped here.
public def lexer_skip_ws(lx: @var Lexer) {
    while lx.pos < lx.src.len() {
        c = lexer_peek(lx, 0)
        if c == 32 or c == 9 or c == 13 or c == 10 {
            lexer_advance(lx)
        } elif c == char_hash() and not lx.keep_comments {
            while lx.pos < lx.src.len() and lexer_peek(lx, 0) != char_newline() {
                lexer_advance(lx)
            }
        } elif c == char_slash() and lexer_peek(lx, 1) == char_star() and not lx.keep_comments {
            bline = lx.line
            bcol = lx.col
            lexer_advance(lx)
            lexer_advance(lx)
            closed = False
            while lx.pos < lx.src.len() {
                if lexer_peek(lx, 0) == char_star() and lexer_peek(lx, 1) == char_slash() {
                    lexer_advance(lx)
                    lexer_advance(lx)
                    closed = True
                    break
                }
                lexer_advance(lx)
            }
            if not closed {
                if lx.ok {
                    lx.ok = False
                    lx.err_line = bline
                    lx.err_col = bcol
                    lx.err_msg = "unterminated block comment"
                }
                return
            }
        } else {
            break
        }
    }
}

# Lex a number: integer or float (with exponent), supporting 0x / 0b / 0o prefixes.
public def lexer_lex_number(lx: @var Lexer) -> Token {
    line = lx.line
    col = lx.col
    start = lx.pos
    is_float = False

    # Integer literal with a radix prefix: 0x1F / 0b1010 / 0o17
    if lexer_peek(lx, 0) == char_digit_0() and
       (lexer_peek(lx, 1) == "x".char_at(0) or lexer_peek(lx, 1) == "X".char_at(0) or
        lexer_peek(lx, 1) == "b".char_at(0) or lexer_peek(lx, 1) == "B".char_at(0) or
        lexer_peek(lx, 1) == "o".char_at(0) or lexer_peek(lx, 1) == "O".char_at(0)) {
        lexer_advance(lx)
        lexer_advance(lx)
        while is_alnum(lexer_peek(lx, 0)) {
            lexer_advance(lx)
        }
        text = lx.src.slice(start, lx.pos)
        return make_token(TokIntLit(), text, line, col)
    }

    while is_digit(lexer_peek(lx, 0)) {
        lexer_advance(lx)
    }
    if lexer_peek(lx, 0) == char_dot() {
        is_float = True
        lexer_advance(lx)
        while is_digit(lexer_peek(lx, 0)) {
            lexer_advance(lx)
        }
    }
    if lexer_peek(lx, 0) == char_e() or lexer_peek(lx, 0) == char_E() {
        is_float = True
        lexer_advance(lx)
        if lexer_peek(lx, 0) == char_plus() or lexer_peek(lx, 0) == char_minus() {
            lexer_advance(lx)
        }
        while is_digit(lexer_peek(lx, 0)) {
            lexer_advance(lx)
        }
    }
    text = lx.src.slice(start, lx.pos)
    if is_float {
        return make_token(TokFloatLit(), text, line, col)
    }
    return make_token(TokIntLit(), text, line, col)
}

# Lex an identifier or keyword.
public def lexer_lex_ident(lx: @var Lexer) -> Token {
    line = lx.line
    col = lx.col
    start = lx.pos
    while is_alnum(lexer_peek(lx, 0)) {
        lexer_advance(lx)
    }
    text = lx.src.slice(start, lx.pos)
    if is_keyword(text) {
        return make_token(keyword_kind(text), text, line, col)
    }
    return make_token(TokIdent(), text, line, col)
}

# Lex a string literal (supports \n \t \r \\ \" \0).
public def lexer_lex_string(lx: @var Lexer) -> Token {
    line = lx.line
    col = lx.col
    lexer_advance(lx)   # opening quote
    text = ""
    while True {
        if lx.pos >= lx.src.len() {
            if lx.ok {
                lx.ok = False
                lx.err_line = line
                lx.err_col = col
                lx.err_msg = "unterminated string literal"
            }
            return make_token(TokStringLit(), text, line, col)
        }
        c = lexer_peek(lx, 0)
        if c == char_quote() {
            lexer_advance(lx)
            break
        }
        if c == char_backslash() {
            lexer_advance(lx)   # backslash
            e = lexer_peek(lx, 0)
            if e == char_n() {
                text = text + "\n"
            } elif e == char_t() {
                text = text + "\t"
            } elif e == char_r() {
                text = text + "\r"
            } elif e == char_backslash() {
                text = text + "\\"
            } elif e == char_quote() {
                text = text + "\""
            } else {
                # Other escapes: drop the backslash and keep the character as-is.
                s = lx.pos
                text = text + lx.src.slice(s, lx.pos)
            }
            lexer_advance(lx)   # consume the escaped character
            pass
        } else {
            s = lx.pos
            lexer_advance(lx)
            text = text + lx.src.slice(s, lx.pos)
            pass
        }
    }
    return make_token(TokStringLit(), text, line, col)
}

# Single-character punctuation code -> TokenKind. Returns TokUnknown when there is no match.
public def punct_kind(c: int) -> TokenKind {
    if c == "(".char_at(0) { return TokLParen() }
    if c == ")".char_at(0) { return TokRParen() }
    if c == "{".char_at(0) { return TokLBrace() }
    if c == "}".char_at(0) { return TokRBrace() }
    if c == "[".char_at(0) { return TokLBracket() }
    if c == "]".char_at(0) { return TokRBracket() }
    if c == ",".char_at(0) { return TokComma() }
    if c == ":".char_at(0) { return TokColon() }
    if c == ";".char_at(0) { return TokSemi() }
    if c == "+".char_at(0) { return TokPlus() }
    if c == "-".char_at(0) { return TokMinus() }
    if c == "*".char_at(0) { return TokStar() }
    if c == "/".char_at(0) { return TokSlash() }
    if c == "%".char_at(0) { return TokPercent() }
    if c == "&".char_at(0) { return TokAmp() }
    if c == "|".char_at(0) { return TokPipe() }
    if c == "^".char_at(0) { return TokCaret() }
    if c == ".".char_at(0) { return TokDot() }
    if c == "@".char_at(0) { return TokAt() }
    if c == "?".char_at(0) { return TokQuestion() }
    if c == "!".char_at(0) { return TokBang() }
    if c == "=".char_at(0) { return TokAssign() }
    if c == "<".char_at(0) { return TokLt() }
    if c == ">".char_at(0) { return TokGt() }
    return TokUnknown()
}

# Full lexical analysis.
public def lexer_tokenize(lx: @var Lexer) -> List[Token] {
    toks = List[Token]()
    while True {
        lexer_skip_ws(lx)
        if lx.pos >= lx.src.len() {
            toks.push(make_eof_token(lx.line, lx.col))
            break
        }
        c = lexer_peek(lx, 0)
        line = lx.line
        col = lx.col

        # keep_comments mode: line/block comments produce TokComment (line comment text excludes the trailing newline;
        # block comment text includes internal newlines, preserved verbatim from the source).
        if lx.keep_comments and c == char_hash() {
            start = lx.pos
            while lx.pos < lx.src.len() and lexer_peek(lx, 0) != char_newline() {
                lexer_advance(lx)
            }
            toks.push(make_token(TokComment(), lx.src.slice(start, lx.pos), line, col))
            continue
        }
        if lx.keep_comments and c == char_slash() and lexer_peek(lx, 1) == char_star() {
            start = lx.pos
            lexer_advance(lx)
            lexer_advance(lx)
            while lx.pos < lx.src.len() {
                if lexer_peek(lx, 0) == char_star() and lexer_peek(lx, 1) == char_slash() {
                    lexer_advance(lx)
                    lexer_advance(lx)
                    break
                }
                lexer_advance(lx)
            }
            toks.push(make_token(TokComment(), lx.src.slice(start, lx.pos), line, col))
            continue
        }

        if is_alpha(c) or c == char_underscore() {
            toks.push(lexer_lex_ident(lx))
            continue
        }
        if is_digit(c) {
            toks.push(lexer_lex_number(lx))
            continue
        }
        if c == char_quote() {
            toks.push(lexer_lex_string(lx))
            continue
        }

        # Multi-character operators (peek two characters first).
        two = ""
        if lx.pos + 1 < lx.src.len() {
            two = lx.src.slice(lx.pos, lx.pos + 2)
        }
        if str_eq(two, "->") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokArrow(), "->", line, col))
            continue
        }
        if str_eq(two, "==") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokEq(), "==", line, col))
            continue
        }
        if str_eq(two, "!=") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokNotEq(), "!=", line, col))
            continue
        }
        if str_eq(two, "<=") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokLe(), "<=", line, col))
            continue
        }
        if str_eq(two, ">=") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokGe(), ">=", line, col))
            continue
        }
        if str_eq(two, "//") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokSlashSlash(), "//", line, col))
            continue
        }
        if str_eq(two, "**") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokStarStar(), "**", line, col))
            continue
        }
        if str_eq(two, "=>") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokFatArrow(), "=>", line, col))
            continue
        }
        if str_eq(two, "<<") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokShl(), "<<", line, col))
            continue
        }
        if str_eq(two, ">>") {
            lexer_advance(lx)
            lexer_advance(lx)
            toks.push(make_token(TokShr(), ">>", line, col))
            continue
        }

        # Single-character punctuation.
        ch = lexer_advance(lx)
        k = punct_kind(ch)
        if k != TokUnknown() {
            toks.push(make_token(k, chr_slice(lx, ch), line, col))
        } else {
            toks.push(make_token(TokUnknown(), chr_slice(lx, ch), line, col))
        }
    }
    return toks
}

# Return the single character just consumed (pos already points at it before the call; slice 1 byte here).
public def chr_slice(lx: @var Lexer, c: int) -> str {
    return lx.src.slice(lx.pos - 1, lx.pos)
}