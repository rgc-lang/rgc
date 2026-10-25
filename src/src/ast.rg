# RGC compiler: AST node definitions
#
# RGC has no inheritance and no null values, so:
#   - Expr is a single-class union with a discriminant field (kind + optional fields)
#   - "no expression" is represented by the NoneLit sentinel (expr == NoneLit means absent)
#   - "no custom type name" is an empty string
# Corresponds to include/rgc/AST.h in the C++ compiler.

import util

public enum ExprKind {
    ExprIntLit
    ExprFloatLit
    ExprBoolLit
    ExprStringLit
    ExprNoneLit
    ExprVar
    ExprUnary
    ExprBinary
    ExprCall
    ExprIf
    ExprBlock
    ExprAssign
    ExprMatch
    ExprMember
    ExprBorrow
    ExprTypeApply
    ExprTry
    ExprAwait
}

public enum StmtKind {
    StmtExpr
    StmtReturn
    StmtFnDef
    StmtClassDef
    StmtEnumDef
    StmtFor
    StmtWhile
    StmtBreak
    StmtContinue
    StmtInterfaceDef
    StmtImport
}

public enum PatternKind {
    PatternVariant
    PatternWildcard
    PatternVar
}

# Type annotations: `int` / `Point` / `List[int]` / `Map[str,int]` / `Maybe[int]`
public class TypeExpr {
    name: str           # "int" / "Point" / "List" / "Map" / "Maybe" / ...
    args: List[TypeExpr]
    is_borrow: bool      # borrow type annotation: @T / @var T
    is_mut_borrow: bool  # @var T
    line: int
    col: int
}

public class Param {
    name: str
    type: TypeExpr      # type annotation (empty name means absent)
}

public class FieldDecl {
    name: str
    type: TypeExpr
}

public class EnumVariant {
    name: str
    named_fields: bool
    fields: List[FieldDecl]
}

public class Pattern {
    kind: PatternKind
    name: str                  # variant name or binding name
    fields: List[Pattern]     # positional sub-patterns
    field_names: List[str]    # named sub-patterns (Rect { w, h })
    named_fields: bool
}

public class MatchArm {
    pattern: Pattern
    body: Expr
}

# Expressions: a union. Unused fields keep safe defaults.
public class Expr {
    kind: ExprKind
    line: int
    col: int

    # literals
    int_val: int
    float_val: float
    bool_val: bool
    str_val: str

    # variable / unary / binary
    name: str          # Var name / called function name / member name / type-application name
    op: str            # Unary/Binary operator
    # Sub-expressions: to avoid LLVM struct self-reference (a class cannot contain itself by value),
    # all direct sub-expressions use List[Expr] (stored on the heap, no recursion).
    lhs: List[Expr]    # Binary lhs / If cond / Match subject / Assign lvalue
    rhs: List[Expr]    # Binary rhs / Assign value
    operand: List[Expr]  # Unary operand
    object: List[Expr]  # method receiver (empty list means no receiver / free function)
    args: List[Expr]   # Call arguments
    type_args: List[TypeExpr]

    # block / if / assignment / match
    stmts: List[Stmt]
    result: List[Expr]          # Block trailing expression (empty list means none)
    cond: List[Expr]            # If condition
    then_block: List[Expr]      # If's then block (a Block expression)
    else_block: List[Expr]      # If's else block (empty list means none)
    target: List[Expr]          # member-assignment lvalue (empty for plain variable assignment)
    value: List[Expr]           # assignment / return value
    subject: List[Expr]         # match subject
    arms: List[MatchArm]

    # type application (generic construction): `List[int]()`
    ta_name: str
    ta_args: List[TypeExpr]

    # assignment with a type annotation: x: int = 42
    type_ann: TypeExpr

    # borrow mutability: @x = False / @var x = True
    is_mut: bool
}

public class Stmt {
    kind: StmtKind
    line: int
    col: int
    expr: Expr             # StmtExpr
    value: Expr           # StmtReturn value (NoneLit when none)
    name: str              # function / class / enum name
    params: List[Param]
    ret_type: TypeExpr   # return type (empty name means None)
    body: List[Stmt]
    fields: List[FieldDecl]
    methods: List[Stmt]
    variants: List[EnumVariant]
    var_name: str         # For loop variable
    iterable: Expr

    # module, generic, and interface declarations
    module_name: str
    module_is_std: bool
    is_public: bool
    is_extern: bool       # extern def: a C-ABI external function declaration (no body)
    type_params: List[str]
    type_param_bounds: List[str]
    interfaces: List[str]
    import_module: str
    import_names: List[str]      # from m import a, b: import names (empty = plain import)
    import_aliases: List[str]    # parallel to import_names; "as" aliases, empty means use the original name
    import_alias: str            # import m as x: the binding alias of a plain import
    import_glob: bool            # from m import *: glob import
    is_async: bool        # async def: the function returns Task[T]
}

# Stable key for qualified calls (module.func): module name + function name + source location.
# Sema records resolution results under it; the IR side uses it to find the module$name internal symbol.
public def expr_call_key(e: @Expr) -> str {
    obj = ""
    if e.object.len() > 0 {
        obj = e.object.get(0).name
    }
    return obj + "." + e.name + "@" + to_string(e.line) + ":" + to_string(e.col)
}

# ---------- Expr constructor helpers ----------

# Create an empty Expr with safe defaults for all fields.
public def new_expr(kind: ExprKind, line: int, col: int) -> Expr {
    e = Expr()
    e.kind = kind
    e.line = line
    e.col = col
    e.int_val = 0
    e.float_val = 0.0
    e.bool_val = False
    e.str_val = ""
    e.name = ""
    e.op = ""
    e.ta_name = ""
    e.lhs = List[Expr]()
    e.rhs = List[Expr]()
    e.operand = List[Expr]()
    e.object = List[Expr]()
    e.result = List[Expr]()
    e.then_block = List[Expr]()
    e.else_block = List[Expr]()
    e.target = List[Expr]()
    e.value = List[Expr]()
    e.subject = List[Expr]()
    e.cond = List[Expr]()
    e.args = List[Expr]()
    e.type_args = List[TypeExpr]()
    e.stmts = List[Stmt]()
    e.arms = List[MatchArm]()
    e.ta_args = List[TypeExpr]()
    e.type_ann = type_expr("")
    e.is_mut = False
    return e
}

# The None sentinel ("no expression"). Note: it is also a valid None literal.
public def none_expr() -> Expr {
    e = new_expr(ExprNoneLit(), 0, 0)
    return e
}

# Wrap one sub-expression into List[Expr] (Expr children are list-stored to avoid LLVM self-reference).
public def one_expr(x: Expr) -> List[Expr] {
    lst = List[Expr]()
    lst.push(x)
    return lst
}

public def make_int_lit(v: int, line: int, col: int) -> Expr {
    e = new_expr(ExprIntLit(), line, col)
    e.int_val = v
    return e
}

public def make_float_lit(v: float, line: int, col: int) -> Expr {
    e = new_expr(ExprFloatLit(), line, col)
    e.float_val = v
    return e
}

public def make_bool_lit(v: bool, line: int, col: int) -> Expr {
    e = new_expr(ExprBoolLit(), line, col)
    e.bool_val = v
    return e
}

public def make_string_lit(v: str, line: int, col: int) -> Expr {
    e = new_expr(ExprStringLit(), line, col)
    e.str_val = v
    return e
}

public def make_var(name: str, line: int, col: int) -> Expr {
    e = new_expr(ExprVar(), line, col)
    e.name = name
    return e
}

public def make_unary(op: str, operand: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprUnary(), line, col)
    e.op = op
    e.operand = one_expr(operand)
    return e
}

public def make_binary(op: str, lhs: Expr, rhs: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprBinary(), line, col)
    e.op = op
    e.lhs = one_expr(lhs)
    e.rhs = one_expr(rhs)
    return e
}

public def make_call(callee: str, args: List[Expr], line: int, col: int) -> Expr {
    e = new_expr(ExprCall(), line, col)
    e.name = callee
    e.args = args
    return e
}

public def make_method_call(obj: Expr, method: str, args: List[Expr],
                            line: int, col: int) -> Expr {
    e = new_expr(ExprCall(), line, col)
    e.object = one_expr(obj)
    e.name = method
    e.args = args
    return e
}

public def make_member(obj: Expr, member: str, line: int, col: int) -> Expr {
    e = new_expr(ExprMember(), line, col)
    e.object = one_expr(obj)
    e.name = member
    return e
}

public def make_assign(name: str, value: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprAssign(), line, col)
    e.name = name
    e.value = one_expr(value)
    return e
}

public def make_member_assign(target: Expr, value: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprAssign(), line, col)
    e.target = one_expr(target)
    e.value = one_expr(value)
    return e
}

# ---------- TypeExpr / Stmt constructor helpers ----------

public def type_expr(name: str) -> TypeExpr {
    t = TypeExpr()
    t.name = name
    t.args = List[TypeExpr]()
    t.is_borrow = False
    t.is_mut_borrow = False
    t.line = 0
    t.col = 0
    return t
}

public def type_expr_at(name: str, line: int, col: int) -> TypeExpr {
    t = type_expr(name)
    t.line = line
    t.col = col
    return t
}

public def type_apply(name: str, args: List[TypeExpr]) -> TypeExpr {
    t = TypeExpr()
    t.name = name
    t.args = args
    t.is_borrow = False
    t.is_mut_borrow = False
    t.line = 0
    t.col = 0
    return t
}

public def type_apply_at(name: str, args: List[TypeExpr], line: int, col: int) -> TypeExpr {
    t = type_apply(name, args)
    t.line = line
    t.col = col
    return t
}

public def make_borrow(operand: Expr, is_mut: bool, line: int, col: int) -> Expr {
    e = new_expr(ExprBorrow(), line, col)
    e.operand = one_expr(operand)
    e.is_mut = is_mut
    return e
}

# Postfix `?`: Result error propagation.
public def make_try(operand: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprTry(), line, col)
    e.operand = one_expr(operand)
    return e
}

# Prefix `await`: wait for a Task and take its payload.
public def make_await(operand: Expr, line: int, col: int) -> Expr {
    e = new_expr(ExprAwait(), line, col)
    e.operand = one_expr(operand)
    return e
}

public def make_expr_stmt(expr: Expr, line: int, col: int) -> Stmt {
    s = Stmt()
    s.kind = StmtExpr()
    s.line = line
    s.col = col
    s.expr = expr
    s.value = none_expr()
    s.ret_type = type_expr("")
    s.iterable = none_expr()
    s.params = List[Param]()
    s.body = List[Stmt]()
    s.fields = List[FieldDecl]()
    s.methods = List[Stmt]()
    s.variants = List[EnumVariant]()
    s.module_name = ""
    s.module_is_std = False
    s.is_public = False
    s.is_extern = False
    s.type_params = List[str]()
    s.type_param_bounds = List[str]()
    s.interfaces = List[str]()
    s.import_module = ""
    s.import_names = List[str]()
    s.import_aliases = List[str]()
    s.import_alias = ""
    s.import_glob = False
    s.is_async = False
    return s
}

public def make_return(value: Expr, line: int, col: int) -> Stmt {
    s = make_expr_stmt(none_expr(), line, col)
    s.kind = StmtReturn()
    s.value = value
    return s
}

# Create an empty Stmt (for function/class/enum definitions).
public def new_stmt(kind: StmtKind, line: int, col: int) -> Stmt {
    s = make_expr_stmt(none_expr(), line, col)
    s.kind = kind
    return s
}

public def make_param(name: str, type: TypeExpr) -> Param {
    p = Param()
    p.name = name
    p.type = type
    return p
}

public def make_field(name: str, type: TypeExpr) -> FieldDecl {
    f = FieldDecl()
    f.name = name
    f.type = type
    return f
}

public def make_enum_variant(name: str, named: bool, fields: List[FieldDecl]) -> EnumVariant {
    v = EnumVariant()
    v.name = name
    v.named_fields = named
    v.fields = fields
    return v
}

public def make_pattern_variant(name: str, fields: List[Pattern]) -> Pattern {
    p = Pattern()
    p.kind = PatternVariant()
    p.name = name
    p.fields = fields
    p.field_names = List[str]()
    return p
}

public def make_pattern_named_variant(name: str, fields: List[Pattern],
                                      field_names: List[str]) -> Pattern {
    p = Pattern()
    p.kind = PatternVariant()
    p.name = name
    p.fields = fields
    p.field_names = field_names
    p.named_fields = True
    return p
}

public def make_pattern_var(name: str) -> Pattern {
    p = Pattern()
    p.kind = PatternVar()
    p.name = name
    p.fields = List[Pattern]()
    p.field_names = List[str]()
    return p
}

public def make_pattern_wildcard() -> Pattern {
    p = Pattern()
    p.kind = PatternWildcard()
    p.name = ""
    p.fields = List[Pattern]()
    p.field_names = List[str]()
    return p
}

public def make_match_arm(pattern: Pattern, body: Expr) -> MatchArm {
    a = MatchArm()
    a.pattern = pattern
    a.body = body
    return a
}

# ---------- list constructor helpers (non-generic, overloaded as needed) ----------

public def list1_expr(a: Expr) -> List[Expr] {
    l = List[Expr]()
    l.push(a)
    return l
}

public def list2_expr(a: Expr, b: Expr) -> List[Expr] {
    l = List[Expr]()
    l.push(a)
    l.push(b)
    return l
}

public def list3_expr(a: Expr, b: Expr, c: Expr) -> List[Expr] {
    l = List[Expr]()
    l.push(a)
    l.push(b)
    l.push(c)
    return l
}

public def list1_type_expr(a: TypeExpr) -> List[TypeExpr] {
    l = List[TypeExpr]()
    l.push(a)
    return l
}

public def list2_type_expr(a: TypeExpr, b: TypeExpr) -> List[TypeExpr] {
    l = List[TypeExpr]()
    l.push(a)
    l.push(b)
    return l
}

public def list1_stmt(a: Stmt) -> List[Stmt] {
    l = List[Stmt]()
    l.push(a)
    return l
}

public def list2_stmt(a: Stmt, b: Stmt) -> List[Stmt] {
    l = List[Stmt]()
    l.push(a)
    l.push(b)
    return l
}

public def list1_str(a: str) -> List[str] {
    l = List[str]()
    l.push(a)
    return l
}

public def list1_param(a: Param) -> List[Param] {
    l = List[Param]()
    l.push(a)
    return l
}

public def list1_pattern(a: Pattern) -> List[Pattern] {
    l = List[Pattern]()
    l.push(a)
    return l
}

public def list1_match_arm(a: MatchArm) -> List[MatchArm] {
    l = List[MatchArm]()
    l.push(a)
    return l
}

public def list1_field_decl(a: FieldDecl) -> List[FieldDecl] {
    l = List[FieldDecl]()
    l.push(a)
    return l
}