# RGC compiler: recursive-descent parser
#
# Produces the AST (the union types defined in ast.rg). Supports:
#   - functions / classes / enums / for / while / return / break / continue / pass
#   - full expression precedence (assignment, or/and/not, comparison, bitwise, shift, +-*/%, unary, postfix)
#   - if expressions (with elif chains), match, block expressions
#   - type annotations (List[int] / Map[str,int] / Maybe[int] / Result[int,str])
# Corresponds to src/parser/Parser.cpp in the C++ compiler.

import util
import token
import types
import ast

public class Parser {
    toks: List[Token]
    pos: int
    ok: bool
    # The first parse error (recorded structurally, rendered by the loader; the loader fills in file).
    err_line: int
    err_col: int
    err_msg: str
}

public def make_parser(toks: List[Token]) -> Parser {
    p = Parser()
    p.toks = toks
    p.pos = 0
    p.ok = True
    p.err_line = 0
    p.err_col = 0
    p.err_msg = ""
    return p
}

public def parser_peek(p: @var Parser) -> Token {
    if p.pos < p.toks.len() {
        return p.toks.get(p.pos)
    }
    return p.toks.get(p.toks.len() - 1)
}

public def parser_peek2(p: @var Parser) -> Token {
    if p.pos + 1 < p.toks.len() {
        return p.toks.get(p.pos + 1)
    }
    return p.toks.get(p.toks.len() - 1)
}

public def parser_advance(p: @var Parser) -> Token {
    t = parser_peek(p)
    if p.pos + 1 < p.toks.len() {
        p.pos = p.pos + 1
    }
    return t
}

public def parser_check(p: @var Parser, k: TokenKind) -> bool {
    return parser_peek(p).kind == k
}

public def parser_match(p: @var Parser, k: TokenKind) -> bool {
    if parser_check(p, k) {
        parser_advance(p)
        return True
    }
    return False
}

public def parser_expect(p: @var Parser, k: TokenKind, what: str) -> Token {
    if parser_check(p, k) {
        return parser_advance(p)
    }
    t = parser_peek(p)
    if p.err_msg.len() == 0 {
        p.err_line = t.line
        p.err_col = t.col
        p.err_msg = "expected " + what + ", found '" + t.text + "'"
    }
    p.ok = False
    return t
}

public def parser_fail(p: @var Parser, msg: str) {
    if p.err_msg.len() == 0 {
        # No position: when the caller's message already contains "at line:col", the renderer only labels the file.
        p.err_msg = msg
    }
    p.ok = False
}

# Positioned failure: the renderer shows the source snippet and caret based on this.
public def parser_fail_at(p: @var Parser, line: int, col: int, msg: str) {
    if p.err_msg.len() == 0 {
        p.err_line = line
        p.err_col = col
        p.err_msg = msg
    }
    p.ok = False
}

# ---------------------------------------------------------------------------
# program / statements
# ---------------------------------------------------------------------------

public def parser_parse_program(p: @var Parser) -> List[Stmt] {
    stmts = List[Stmt]()
    while not parser_check(p, TokEof()) {
        before = p.pos
        s = parser_parse_stmt(p)
        stmts.push(s)
        if not p.ok {
            break
        }
        if p.pos == before {
            # Unrecognized syntax: skip the token to avoid an infinite loop.
            parser_advance(p)
        }
    }
    return stmts
}

# Top-level import / from: records the module name; the loader loads and merges before Sema.
# Paths are hierarchical: import net/tcp (binds the last segment tcp; overridable with as).
# from m import a, b as c: names and aliases are recorded in the statement; Sema builds scoped imports;
# from m import *: glob import; public from m import ...: re-export (pub use).
public def parser_parse_import(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    is_from = parser_match(p, TokFrom())
    if not is_from {
        parser_expect(p, TokImport(), "'import'")
    }
    module = parser_expect(p, TokIdent(), "module name").text
    while parser_match(p, TokSlash()) {
        module = module + "/" +
                 parser_expect(p, TokIdent(), "module path segment after '/'").text
    }
    s = new_stmt(StmtImport(), line, col)
    s.import_module = module
    if is_from {
        parser_expect(p, TokImport(), "'import'")
        if parser_match(p, TokStar()) {
            s.import_glob = True
            return s
        }
        while True {
            name = parser_expect(p, TokIdent(), "imported name").text
            s.import_names.push(name)
            alias = ""
            if parser_match(p, TokAs()) {
                alias = parser_expect(p, TokIdent(), "alias name after 'as'").text
            }
            s.import_aliases.push(alias)
            if not parser_match(p, TokComma()) {
                break
            }
        }
    } elif parser_match(p, TokAs()) {
        s.import_alias = parser_expect(p, TokIdent(), "alias name after 'as'").text
    }
    return s
}

public def parser_parse_stmt(p: @var Parser) -> Stmt {
    if parser_check(p, TokImport()) or parser_check(p, TokFrom()) {
        return parser_parse_import(p)
    }
    if parser_match(p, TokPublic()) {
        t = parser_peek(p)
        if parser_match(p, TokAsync()) {
            parser_expect(p, TokDef(), "'def' after 'async'")
            s = parser_parse_fn_def(p)
            s.is_async = True
            s.is_public = True
            return s
        }
        if parser_match(p, TokDef()) {
            s = parser_parse_fn_def(p)
            s.is_public = True
            return s
        }
        if parser_match(p, TokClass()) {
            s = parser_parse_class_def(p)
            s.is_public = True
            return s
        }
        if parser_match(p, TokEnum()) {
            s = parser_parse_enum_def(p)
            s.is_public = True
            return s
        }
        if parser_match(p, TokInterface()) {
            s = parser_parse_interface_def(p)
            s.is_public = True
            return s
        }
        if parser_check(p, TokFrom()) {
            s = parser_parse_import(p)
            s.is_public = True
            return s
        }
        parser_fail(p, "expected 'def'/'class'/'enum'/'interface' after 'public' at " +
                   to_string(t.line) + ":" + to_string(t.col))
        return make_expr_stmt(none_expr(), t.line, t.col)
    }
    # async def: a thread-backed task (no async methods / async main).
    if parser_check(p, TokAsync()) and parser_peek2(p).kind == TokDef() {
        parser_advance(p)   # async
        parser_advance(p)   # def
        s = parser_parse_fn_def(p)
        s.is_async = True
        return s
    }
    # extern def: a C-ABI external function declaration (`extern` is a contextual modifier, not a keyword).
    t = parser_peek(p)
    if t.kind == TokIdent() and str_eq(t.text, "extern") and
       parser_peek2(p).kind == TokDef() {
        parser_advance(p)   # extern
        parser_advance(p)   # def
        s = parser_parse_fn_def(p)
        s.is_extern = True
        return s
    }
    if parser_match(p, TokDef()) {
        return parser_parse_fn_def(p)
    }
    if parser_match(p, TokClass()) {
        return parser_parse_class_def(p)
    }
    if parser_match(p, TokEnum()) {
        return parser_parse_enum_def(p)
    }
    if parser_match(p, TokInterface()) {
        return parser_parse_interface_def(p)
    }
    if parser_match(p, TokFor()) {
        return parser_parse_for(p)
    }
    if parser_match(p, TokWhile()) {
        return parser_parse_while(p)
    }
    if parser_match(p, TokReturn()) {
        return parser_parse_return(p)
    }
    if parser_match(p, TokBreak()) {
        s = new_stmt(StmtBreak(), parser_peek(p).line, parser_peek(p).col)
        return s
    }
    if parser_match(p, TokContinue()) {
        s = new_stmt(StmtContinue(), parser_peek(p).line, parser_peek(p).col)
        return s
    }
    if parser_match(p, TokPass()) {
        return make_expr_stmt(none_expr(), parser_peek(p).line, parser_peek(p).col)
    }
    return parser_parse_expr_stmt(p)
}

# Declarations with type annotations: x: int = 42
public def parser_parse_expr_stmt(p: @var Parser) -> Stmt {
    t = parser_peek(p)
    if t.kind == TokIdent() and parser_peek2(p).kind == TokColon() {
        parser_advance(p)   # variable name
        parser_advance(p)    # ':'
        ta = parser_parse_type_expr(p)
        parser_expect(p, TokAssign(), "'='")
        value = parser_parse_expr(p)
        e = make_assign(t.text, value, t.line, t.col)
        e.type_ann = ta
        return make_expr_stmt(e, t.line, t.col)
    }
    e = parser_parse_assignment(p)
    return make_expr_stmt(e, t.line, t.col)
}

public def parser_parse_return(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    v = none_expr()
    if not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) and
       not parser_check(p, TokDef()) and not parser_check(p, TokIf()) {
        v = parser_parse_expr(p)
    }
    return make_return(v, line, col)
}

public def parser_parse_for(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    vname = parser_expect(p, TokIdent(), "loop variable").text
    parser_expect(p, TokIn(), "'in'")
    it = parser_parse_expr(p)
    blk = parser_parse_block(p)
    s = new_stmt(StmtFor(), line, col)
    s.var_name = vname
    s.iterable = it
    s.body = blk
    return s
}

public def parser_parse_while(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    cond = parser_parse_expr(p)
    blk = parser_parse_block(p)
    s = new_stmt(StmtWhile(), line, col)
    s.value = cond
    s.body = blk
    return s
}

# Interface definitions: methods have signatures only, no bodies.
public def parser_parse_interface_def(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    name = parser_expect(p, TokIdent(), "interface name").text
    s = new_stmt(StmtInterfaceDef(), line, col)
    s.name = name
    parser_expect(p, TokLBrace(), "'{'")
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        t = parser_peek(p)
        if not parser_match(p, TokDef()) {
            parser_fail(p, "expected method declaration in interface at " +
                       to_string(t.line) + ":" + to_string(t.col))
            break
        }
        s.methods.push(parser_parse_fn_def(p))
        if not p.ok {
            break
        }
    }
    parser_expect(p, TokRBrace(), "'}'")
    return s
}

# Function definitions.
public def parser_parse_fn_def(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    name = parser_expect(p, TokIdent(), "function name").text
    s = new_stmt(StmtFnDef(), line, col)
    s.name = name
    if parser_match(p, TokLBracket()) {
        if not parser_check(p, TokRBracket()) {
            while True {
                s.type_params.push(parser_expect(p, TokIdent(), "type parameter name").text)
                if parser_match(p, TokColon()) {
                    s.type_param_bounds.push(
                        parser_expect(p, TokIdent(), "interface name").text)
                } else {
                    s.type_param_bounds.push("")
                }
                if not parser_match(p, TokComma()) {
                    break
                }
            }
        }
        parser_expect(p, TokRBracket(), "']'")
    }
    parser_expect(p, TokLParen(), "'('")
    params = List[Param]()
    if not parser_check(p, TokRParen()) {
        while True {
            pn = parser_expect(p, TokIdent(), "parameter name").text
            pt = type_expr("")
            if parser_check(p, TokColon()) {
                parser_advance(p)
                pt = parser_parse_type_expr(p)
            } elif not str_eq(pn, "self") {
                parser_fail(p, "expected ':' after parameter '" + pn + "'")
            }
            params.push(make_param(pn, pt))
            if not parser_match(p, TokComma()) {
                break
            }
        }
    }
    parser_expect(p, TokRParen(), "')'")
    rt = type_expr("")
    if parser_match(p, TokArrow()) {
        rt = parser_parse_type_expr(p)
    }
    s.params = params
    s.ret_type = rt
    if parser_check(p, TokLBrace()) {
        s.body = parser_parse_block(p)
    }
    return s
}

# Class definitions.
public def parser_parse_class_def(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    name = parser_expect(p, TokIdent(), "class name").text
    s = new_stmt(StmtClassDef(), line, col)
    s.name = name
    if parser_match(p, TokLBracket()) {
        if not parser_check(p, TokRBracket()) {
            while True {
                s.type_params.push(parser_expect(p, TokIdent(), "type parameter name").text)
                if parser_match(p, TokColon()) {
                    s.type_param_bounds.push(
                        parser_expect(p, TokIdent(), "interface name").text)
                } else {
                    s.type_param_bounds.push("")
                }
                if not parser_match(p, TokComma()) {
                    break
                }
            }
        }
        parser_expect(p, TokRBracket(), "']'")
    }
    if parser_match(p, TokColon()) {
        while True {
            s.interfaces.push(parser_expect(p, TokIdent(), "interface name").text)
            if not parser_match(p, TokComma()) {
                break
            }
        }
    }
    parser_expect(p, TokLBrace(), "'{'")
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        before = p.pos
        if parser_check(p, TokAsync()) and parser_peek2(p).kind == TokDef() {
            parser_advance(p)
            parser_advance(p)
            m = parser_parse_fn_def(p)
            m.is_async = True
            s.methods.push(m)
        } elif parser_check(p, TokDef()) {
            parser_advance(p)
            s.methods.push(parser_parse_fn_def(p))
        } else {
            fname = parser_expect(p, TokIdent(), "field name").text
            parser_expect(p, TokColon(), "':'")
            ftype = parser_parse_type_expr(p)
            s.fields.push(make_field(fname, ftype))
        }
        if not p.ok {
            break
        }
        if p.pos == before {
            parser_advance(p)
        }
    }
    parser_expect(p, TokRBrace(), "'}'")
    return s
}

# Enum definitions.
public def parser_parse_enum_def(p: @var Parser) -> Stmt {
    line = parser_peek(p).line
    col = parser_peek(p).col
    name = parser_expect(p, TokIdent(), "enum name").text
    s = new_stmt(StmtEnumDef(), line, col)
    s.name = name
    if parser_match(p, TokLBracket()) {
        if not parser_check(p, TokRBracket()) {
            while True {
                s.type_params.push(parser_expect(p, TokIdent(), "type parameter name").text)
                s.type_param_bounds.push("")
                if not parser_match(p, TokComma()) {
                    break
                }
            }
        }
        parser_expect(p, TokRBracket(), "']'")
    }
    parser_expect(p, TokLBrace(), "'{'")
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        before = p.pos
        vname = parser_expect(p, TokIdent(), "variant name").text
        v = make_enum_variant(vname, False, List[FieldDecl]())
        if parser_match(p, TokLParen()) {
            v.named_fields = False
            if not parser_check(p, TokRParen()) {
                while True {
                    v.fields.push(make_field("", parser_parse_type_expr(p)))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRParen(), "')'")
        } elif parser_match(p, TokLBrace()) {
            v.named_fields = True
            if not parser_check(p, TokRBrace()) {
                while True {
                    fname = parser_expect(p, TokIdent(), "field name").text
                    parser_expect(p, TokColon(), "':'")
                    ftype = parser_parse_type_expr(p)
                    v.fields.push(make_field(fname, ftype))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRBrace(), "'}'")
        }
        s.variants.push(v)
        if not p.ok {
            break
        }
        if p.pos == before {
            parser_advance(p)
        }
    }
    parser_expect(p, TokRBrace(), "'}'")
    return s
}

# ---------------------------------------------------------------------------
# Type annotations
# ---------------------------------------------------------------------------

# Type annotations: int / float / bool / str / None / Point / List[int] / Map[str,int] ...
public def parser_parse_type_expr(p: @var Parser) -> TypeExpr {
    t = parser_peek(p)
    if t.kind == TokIdent() {
        parser_advance(p)
        if parser_check(p, TokLBracket()) {
            parser_advance(p)
            args = List[TypeExpr]()
            if not parser_check(p, TokRBracket()) {
                while True {
                    args.push(parser_parse_type_expr(p))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRBracket(), "']'")
            return type_apply_at(t.text, args, t.line, t.col)
        }
        return type_expr_at(t.text, t.line, t.col)
    }
    if t.kind == TokNone() {
        parser_advance(p)
        return type_expr("None")
    }
    if t.kind == TokAt() {
        # Borrow type annotations: @T / @var T — parsed as the inner type with is_borrow set.
        parser_advance(p)
        is_mut = False
        if parser_check(p, TokIdent()) and str_eq(parser_peek(p).text, "var") {
            parser_advance(p)
            is_mut = True
        }
        inner = parser_parse_type_expr(p)
        inner.is_borrow = True
        inner.is_mut_borrow = is_mut
        return inner
    }
    parser_fail_at(p, t.line, t.col, "expected type annotation")
    return type_expr("")
}

# ---------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------

public def parser_parse_expr(p: @var Parser) -> Expr {
    return parser_parse_assignment(p)
}

public def parser_parse_assignment(p: @var Parser) -> Expr {
    lhs = parser_parse_logical_or(p)
    if not parser_check(p, TokAssign()) {
        return lhs
    }
    t = parser_advance(p)
    rhs = parser_parse_assignment(p)
    if lhs.kind == ExprVar() {
        line = lhs.line
        col = lhs.col
        return make_assign(lhs.name, rhs, line, col)
    } elif lhs.kind == ExprMember() {
        line = lhs.line
        col = lhs.col
        return make_member_assign(lhs, rhs, line, col)
    } else {
        parser_fail_at(p, lhs.line, lhs.col, "invalid assignment target")
        return lhs
    }
}

public def parser_parse_logical_or(p: @var Parser) -> Expr {
    lhs = parser_parse_logical_and(p)
    while parser_match(p, TokOr()) {
        rhs = parser_parse_logical_and(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary("or", lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_logical_and(p: @var Parser) -> Expr {
    lhs = parser_parse_not(p)
    while parser_match(p, TokAnd()) {
        rhs = parser_parse_not(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary("and", lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_not(p: @var Parser) -> Expr {
    if parser_match(p, TokNot()) {
        line = parser_peek(p).line
        col = parser_peek(p).col
        return make_unary("not", parser_parse_not(p), line, col)
    }
    return parser_parse_comparison(p)
}

public def parser_parse_comparison(p: @var Parser) -> Expr {
    lhs = parser_parse_bitwise_or(p)
    while parser_check(p, TokEq()) or parser_check(p, TokNotEq()) or
          parser_check(p, TokLt()) or parser_check(p, TokGt()) or
          parser_check(p, TokLe()) or parser_check(p, TokGe()) {
        t = parser_advance(p)
        rhs = parser_parse_bitwise_or(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary(t.text, lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_bitwise_or(p: @var Parser) -> Expr {
    lhs = parser_parse_bitwise_xor(p)
    while parser_match(p, TokPipe()) {
        rhs = parser_parse_bitwise_xor(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary("|", lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_bitwise_xor(p: @var Parser) -> Expr {
    lhs = parser_parse_bitwise_and(p)
    while parser_match(p, TokCaret()) {
        rhs = parser_parse_bitwise_and(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary("^", lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_bitwise_and(p: @var Parser) -> Expr {
    lhs = parser_parse_shift(p)
    while parser_match(p, TokAmp()) {
        rhs = parser_parse_shift(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary("&", lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_shift(p: @var Parser) -> Expr {
    lhs = parser_parse_additive(p)
    while parser_check(p, TokShl()) or parser_check(p, TokShr()) {
        t = parser_advance(p)
        rhs = parser_parse_additive(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary(t.text, lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_additive(p: @var Parser) -> Expr {
    lhs = parser_parse_multiplicative(p)
    while parser_check(p, TokPlus()) or parser_check(p, TokMinus()) {
        t = parser_advance(p)
        rhs = parser_parse_multiplicative(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary(t.text, lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_multiplicative(p: @var Parser) -> Expr {
    lhs = parser_parse_unary(p)
    while parser_check(p, TokStar()) or parser_check(p, TokSlash()) or
          parser_check(p, TokPercent()) or parser_check(p, TokSlashSlash()) or
          parser_check(p, TokStarStar()) {
        t = parser_advance(p)
        rhs = parser_parse_unary(p)
        line = lhs.line
        col = lhs.col
        lhs = make_binary(t.text, lhs, rhs, line, col)
    }
    return lhs
}

public def parser_parse_unary(p: @var Parser) -> Expr {
    if parser_check(p, TokAwait()) {
        t = parser_advance(p)
        return make_await(parser_parse_unary(p), t.line, t.col)
    }
    if parser_check(p, TokAt()) {
        t = parser_advance(p)
        line = t.line
        col = t.col
        # `@var x` mutable borrow.
        is_mut = False
        if parser_check(p, TokIdent()) and str_eq(parser_peek(p).text, "var") {
            parser_advance(p)
            is_mut = True
        }
        return make_borrow(parser_parse_unary(p), is_mut, line, col)
    }
    if parser_check(p, TokMinus()) {
        t = parser_advance(p)
        line = parser_peek(p).line
        col = parser_peek(p).col
        return make_unary("-", parser_parse_unary(p), line, col)
    }
    return parser_parse_postfix(p)
}

# Postfix: member access `a.b`, method calls `a.b(args)`, and generic constructions `Box[int](...)`.
public def parser_parse_postfix(p: @var Parser) -> Expr {
    e = parser_parse_primary(p)
    while True {
        if parser_check(p, TokDot()) {
            parser_advance(p)
            member = parser_expect(p, TokIdent(), "member name").text
            line = e.line
            col = e.col
            m = make_member(e, member, line, col)
            e = m
        } elif parser_check(p, TokLParen()) and e.kind == ExprMember() {
            parser_advance(p)
            args = List[Expr]()
            if not parser_check(p, TokRParen()) {
                while True {
                    args.push(parser_parse_assignment(p))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRParen(), "')'")
            e = make_method_call(e.object.get(0), e.name, args, e.line, e.col)
        } elif parser_check(p, TokQuestion()) {
            t = parser_advance(p)
            e = make_try(e, t.line, t.col)
        } elif parser_check(p, TokLParen()) and e.kind == ExprTypeApply() {
            parser_advance(p)
            args = List[Expr]()
            if not parser_check(p, TokRParen()) {
                while True {
                    args.push(parser_parse_assignment(p))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRParen(), "')'")
            c = new_expr(ExprCall(), e.line, e.col)
            c.name = e.ta_name
            c.type_args = e.ta_args
            c.args = args
            e = c
        } else {
            break
        }
    }
    return e
}

# Primary expressions: literals / identifiers / calls / if / match / blocks / parentheses.
public def parser_parse_primary(p: @var Parser) -> Expr {
    t = parser_peek(p)
    if t.kind == TokIntLit() {
        parser_advance(p)
        return make_int_lit(parse_int_text(t.text), t.line, t.col)
    }
    if t.kind == TokFloatLit() {
        parser_advance(p)
        return make_float_lit(parse_float_text(t.text), t.line, t.col)
    }
    if t.kind == TokTrue() {
        parser_advance(p)
        return make_bool_lit(True, t.line, t.col)
    }
    if t.kind == TokFalse() {
        parser_advance(p)
        return make_bool_lit(False, t.line, t.col)
    }
    if t.kind == TokStringLit() {
        parser_advance(p)
        return make_string_lit(t.text, t.line, t.col)
    }
    if t.kind == TokNone() {
        parser_advance(p)
        return none_expr()
    }
    if t.kind == TokIdent() {
        parser_advance(p)
        if parser_check(p, TokLParen()) {
            parser_advance(p)
            args = List[Expr]()
            if not parser_check(p, TokRParen()) {
                while True {
                    args.push(parser_parse_assignment(p))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRParen(), "')'")
            return make_call(t.text, args, t.line, t.col)
        }
        if parser_check(p, TokLBracket()) {
            parser_advance(p)
            targs = List[TypeExpr]()
            if not parser_check(p, TokRBracket()) {
                while True {
                    targs.push(parser_parse_type_expr(p))
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRBracket(), "']'")
            ta = new_expr(ExprTypeApply(), t.line, t.col)
            ta.ta_name = t.text
            ta.ta_args = targs
            return ta
        }
        return make_var(t.text, t.line, t.col)
    }
    if t.kind == TokIf() {
        return parser_parse_if_expr(p)
    }
    if t.kind == TokMatch() {
        return parser_parse_match_expr(p)
    }
    if t.kind == TokLBrace() {
        blk = parser_parse_block_expr(p)
        return blk
    }
    if t.kind == TokLParen() {
        parser_advance(p)
        inner = parser_parse_expr(p)
        parser_expect(p, TokRParen(), "')'")
        return inner
    }
    parser_fail_at(p, t.line, t.col, "unexpected token '" + t.text + "'")
    return none_expr()
}

# Integer literal parsing: decimal / 0x / 0b / 0o.
public def parse_int_text(text: str) -> int {
    if text.len() > 2 and text.char_at(0) == "0".char_at(0) {
        p = text.char_at(1)
        if p == "x".char_at(0) or p == "X".char_at(0) {
            return hex_to_int(text.slice(2, text.len()))
        }
        if p == "b".char_at(0) or p == "B".char_at(0) {
            return bin_to_int(text.slice(2, text.len()))
        }
        if p == "o".char_at(0) or p == "O".char_at(0) {
            return oct_to_int(text.slice(2, text.len()))
        }
    }
    return dec_to_int(text)
}

public def hex_to_int(s: str) -> int {
    v = 0
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        d = 0
        if c >= "0".char_at(0) and c <= "9".char_at(0) {
            d = c - "0".char_at(0)
        } elif c >= "a".char_at(0) and c <= "f".char_at(0) {
            d = c - "a".char_at(0) + 10
        } elif c >= "A".char_at(0) and c <= "F".char_at(0) {
            d = c - "A".char_at(0) + 10
        }
        v = v * 16 + d
        i = i + 1
    }
    return v
}

public def bin_to_int(s: str) -> int {
    v = 0
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        d = 0
        if c == "1".char_at(0) {
            d = 1
        }
        v = v * 2 + d
        i = i + 1
    }
    return v
}

public def oct_to_int(s: str) -> int {
    v = 0
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        d = c - "0".char_at(0)
        v = v * 8 + d
        i = i + 1
    }
    return v
}

public def dec_to_int(s: str) -> int {
    v = 0
    neg = False
    i = 0
    if s.len() > 0 and s.char_at(0) == "-".char_at(0) {
        neg = True
        i = 1
    }
    while i < s.len() {
        v = v * 10 + (s.char_at(i) - "0".char_at(0))
        i = i + 1
    }
    if neg {
        return 0 - v
    }
    return v
}

public def parse_float_text(text: str) -> float {
    # str.to_int is unreliable here (floats). Call a runtime helper: hand the text to
    # the C library's atof — the RGC compiler backend maps this function to atof.
    return str_to_float(text)
}

# If expressions (including elif chains).
public def parser_parse_if_expr(p: @var Parser) -> Expr {
    line = parser_peek(p).line
    col = parser_peek(p).col
    parser_expect(p, TokIf(), "'if'")
    cond = parser_parse_expr(p)
    thenb = parser_parse_block_expr(p)
    e = new_expr(ExprIf(), line, col)
    e.cond = one_expr(cond)
    e.then_block = one_expr(thenb)
    e.else_block = List[Expr]()
    if parser_match(p, TokElif()) {
        e.else_block = one_expr(parser_parse_elif_tail(p))
    } elif parser_match(p, TokElse()) {
        e.else_block = one_expr(parser_parse_block_expr(p))
    }
    return e
}

public def parser_parse_elif_tail(p: @var Parser) -> Expr {
    line = parser_peek(p).line
    col = parser_peek(p).col
    cond = parser_parse_expr(p)
    thenb = parser_parse_block_expr(p)
    e = new_expr(ExprIf(), line, col)
    e.cond = one_expr(cond)
    e.then_block = one_expr(thenb)
    e.else_block = List[Expr]()
    if parser_match(p, TokElif()) {
        e.else_block = one_expr(parser_parse_elif_tail(p))
    } elif parser_match(p, TokElse()) {
        e.else_block = one_expr(parser_parse_block_expr(p))
    }
    return e
}

# Match expressions.
public def parser_parse_match_expr(p: @var Parser) -> Expr {
    line = parser_peek(p).line
    col = parser_peek(p).col
    parser_expect(p, TokMatch(), "'match'")
    subj = parser_parse_expr(p)
    parser_expect(p, TokLBrace(), "'{'")
    e = new_expr(ExprMatch(), line, col)
    e.subject = one_expr(subj)
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        if not parser_match(p, TokCase()) {
            parser_fail(p, "expected 'case' in match")
            break
        }
        pat = parser_parse_pattern(p)
        parser_expect(p, TokFatArrow(), "'=>'")
        body = parser_parse_expr(p)
        e.arms.push(make_match_arm(pat, body))
    }
    parser_expect(p, TokRBrace(), "'}'")
    return e
}

public def parser_parse_pattern(p: @var Parser) -> Pattern {
    t = parser_peek(p)
    if t.kind == TokIdent() and str_eq(t.text, "_") {
        parser_advance(p)
        return make_pattern_wildcard()
    }
    if t.kind == TokIdent() {
        parser_advance(p)
        if parser_check(p, TokLParen()) {
            parser_advance(p)
            fields = List[Pattern]()
            if not parser_check(p, TokRParen()) {
                while True {
                    if parser_check(p, TokIdent()) and str_eq(parser_peek(p).text, "_") {
                        parser_advance(p)
                        fields.push(make_pattern_wildcard())
                    } else {
                        fields.push(make_pattern_var(parser_expect(p, TokIdent(), "binding name").text))
                    }
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRParen(), "')'")
            return make_pattern_variant(t.text, fields)
        }
        if parser_check(p, TokLBrace()) {
            parser_advance(p)
            fields = List[Pattern]()
            fnames = List[str]()
            if not parser_check(p, TokRBrace()) {
                while True {
                    if parser_check(p, TokIdent()) and str_eq(parser_peek(p).text, "_") {
                        parser_advance(p)
                        fields.push(make_pattern_wildcard())
                        fnames.push("")
                    } else {
                        nm = parser_expect(p, TokIdent(), "binding name").text
                        fields.push(make_pattern_var(nm))
                        fnames.push(nm)
                    }
                    if not parser_match(p, TokComma()) {
                        break
                    }
                }
            }
            parser_expect(p, TokRBrace(), "'}'")
            return make_pattern_named_variant(t.text, fields, fnames)
        }
        return make_pattern_var(t.text)
    }
    parser_fail_at(p, t.line, t.col, "invalid pattern")
    return make_pattern_wildcard()
}

# Blocks (as statement lists).
public def parser_parse_block(p: @var Parser) -> List[Stmt] {
    parser_expect(p, TokLBrace(), "'{'")
    stmts = List[Stmt]()
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        before = p.pos
        s = parser_parse_stmt(p)
        stmts.push(s)
        if not p.ok {
            break
        }
        if p.pos == before {
            parser_advance(p)
        }
    }
    parser_expect(p, TokRBrace(), "'}'")
    return stmts
}

# Block expressions (the trailing expression is the value).
public def parser_parse_block_expr(p: @var Parser) -> Expr {
    line = parser_peek(p).line
    col = parser_peek(p).col
    parser_expect(p, TokLBrace(), "'{'")
    e = new_expr(ExprBlock(), line, col)
    while not parser_check(p, TokRBrace()) and not parser_check(p, TokEof()) {
        before = p.pos
        s = parser_parse_stmt(p)
        if s.kind == StmtExpr() and parser_check(p, TokRBrace()) {
            e.result = one_expr(s.expr)
        } else {
            e.stmts.push(s)
        }
        if not p.ok {
            break
        }
        if p.pos == before {
            parser_advance(p)
        }
    }
    parser_expect(p, TokRBrace(), "'}'")
    return e
}