# RGC compiler: token definitions and the keyword table
#
# The TokenKind enum covers every RGC lexical token (mirroring include/rgc/Token.h in the C++ compiler).
# Enum comparison (== / !=) is implemented by the RGC compiler itself via discriminant comparison.

import util

public enum TokenKind {
    TokIdent         # identifier
    TokIntLit        # integer literal
    TokFloatLit      # float literal
    TokStringLit     # string literal
    TokDef
    TokClass
    TokEnum
    TokMatch
    TokCase
    TokIf
    TokElif
    TokElse
    TokFor
    TokIn
    TokWhile
    TokBreak
    TokContinue
    TokPass
    TokReturn
    TokImport
    TokFrom
    TokAs
    TokAnd
    TokOr
    TokNot
    TokTrue
    TokFalse
    TokNone
    TokInterface
    TokPublic
    TokAsync
    TokAwait
    TokLParen
    TokRParen
    TokLBrace
    TokRBrace
    TokLBracket
    TokRBracket
    TokComma
    TokColon
    TokDot
    TokArrow
    TokFatArrow
    TokSemi
    TokPlus
    TokMinus
    TokStar
    TokSlash
    TokPercent
    TokSlashSlash
    TokStarStar
    TokAssign
    TokEq
    TokBang
    TokNotEq
    TokLt
    TokGt
    TokLe
    TokGe
    TokAmp
    TokPipe
    TokCaret
    TokShl
    TokShr
    TokAt
    TokQuestion
    TokComment
    TokEof
    TokUnknown
}

public class Token {
    kind: TokenKind
    text: str
    line: int
    col: int
}

# Keyword table (all RGC keywords come from the Python ecosystem; no Rust vocabulary).
# Note: `range`/`to_string`/`print` are built-in functions, not keywords.
public def keyword_list() -> List[str] {
    ks = List[str]()
    ks.push("def")
    ks.push("class")
    ks.push("enum")
    ks.push("match")
    ks.push("case")
    ks.push("if")
    ks.push("elif")
    ks.push("else")
    ks.push("for")
    ks.push("in")
    ks.push("while")
    ks.push("break")
    ks.push("continue")
    ks.push("pass")
    ks.push("return")
    ks.push("import")
    ks.push("from")
    ks.push("as")
    ks.push("and")
    ks.push("or")
    ks.push("not")
    ks.push("True")
    ks.push("False")
    ks.push("None")
    ks.push("interface")
    ks.push("public")
    ks.push("async")
    ks.push("await")
    return ks
}

# Whether an identifier is a keyword (content comparison; == cannot be used).
public def is_keyword(s: str) -> bool {
    for k in keyword_list() {
        if str_eq(s, k) {
            return True
        }
    }
    return False
}

# Map keyword text to a TokenKind enum value.
# Returns TokIdent when it is not a keyword (matching the C++ lexer).
public def keyword_kind(s: str) -> TokenKind {
    if str_eq(s, "def") { return TokDef() }
    if str_eq(s, "class") { return TokClass() }
    if str_eq(s, "enum") { return TokEnum() }
    if str_eq(s, "match") { return TokMatch() }
    if str_eq(s, "case") { return TokCase() }
    if str_eq(s, "if") { return TokIf() }
    if str_eq(s, "elif") { return TokElif() }
    if str_eq(s, "else") { return TokElse() }
    if str_eq(s, "for") { return TokFor() }
    if str_eq(s, "in") { return TokIn() }
    if str_eq(s, "while") { return TokWhile() }
    if str_eq(s, "break") { return TokBreak() }
    if str_eq(s, "continue") { return TokContinue() }
    if str_eq(s, "pass") { return TokPass() }
    if str_eq(s, "return") { return TokReturn() }
    if str_eq(s, "import") { return TokImport() }
    if str_eq(s, "from") { return TokFrom() }
    if str_eq(s, "as") { return TokAs() }
    if str_eq(s, "and") { return TokAnd() }
    if str_eq(s, "or") { return TokOr() }
    if str_eq(s, "not") { return TokNot() }
    if str_eq(s, "True") { return TokTrue() }
    if str_eq(s, "False") { return TokFalse() }
    if str_eq(s, "None") { return TokNone() }
    if str_eq(s, "interface") { return TokInterface() }
    if str_eq(s, "public") { return TokPublic() }
    if str_eq(s, "async") { return TokAsync() }
    if str_eq(s, "await") { return TokAwait() }
    return TokIdent()
}

# Construct a Token.
public def make_token(kind: TokenKind, text: str, line: int, col: int) -> Token {
    t = Token()
    t.kind = kind
    t.text = text
    t.line = line
    t.col = col
    return t
}

# Construct an EOF token.
public def make_eof_token(line: int, col: int) -> Token {
    return make_token(TokEof(), "", line, col)
}