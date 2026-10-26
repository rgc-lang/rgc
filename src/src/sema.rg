# RGC compiler: semantic analysis (lightweight)
#
# Responsibilities:
#   1. Register signatures and layouts of all functions / classes / enums (for the IR generator)
#   2. Check expressions: variables declared, functions exist, argument counts, binary operator types
#   3. Check return types
# Registries are encoded as Map[str,str]/Map[str,int] (List/Map value types only support scalars/str).

import util
import types
import ast
import token
import parser
import diag

# Parsed `format` placeholder spec (the text between `{` and `}`).
# align: 0 = default, 1 = left, 2 = right, 3 = center.
# conv:  0 = default, 1 = d, 2 = x, 3 = X, 4 = o, 5 = b,
#        6 = f, 7 = e, 8 = E, 9 = g, 10 = G, 11 = s.
public class FmtSpecInfo {
    ok: bool
    error: str
    align: int
    zero: int
    plus: int
    alt: int
    width: int
    precision: int
    conv: int

    def fail(self, spec: str, msg: str) {
        if self.ok {
            self.ok = False
            self.error = "invalid format specifier `" + spec + "`: " + msg
        }
    }
}

def sema_fmt_digit(c: int) -> bool {
    return c >= 48 and c <= 57
}

public def sema_format_spec_parse(spec: str, kind: str) -> FmtSpecInfo {
    r = FmtSpecInfo()
    r.ok = True
    r.error = ""
    r.align = 0
    r.zero = 0
    r.plus = 0
    r.alt = 0
    r.width = 0
    r.precision = -1
    r.conv = 0

    i = 0
    # `{:spec}`: the colon separates the spec from the (unsupported) field name.
    if i < spec.len() and spec.char_at(i) == ":".char_at(0) {
        i = i + 1
    }
    if i < spec.len() {
        c = spec.char_at(i)
        if c == "<".char_at(0) {
            r.align = 1
            i = i + 1
        } elif c == ">".char_at(0) {
            r.align = 2
            i = i + 1
        } elif c == "^".char_at(0) {
            r.align = 3
            i = i + 1
        }
    }

    while i < spec.len() {
        c = spec.char_at(i)
        if c == "#".char_at(0) {
            if r.alt == 1 {
                r.fail(spec, "duplicate `#` flag")
            }
            r.alt = 1
            i = i + 1
        } elif c == "+".char_at(0) {
            if r.plus == 1 {
                r.fail(spec, "duplicate `+` flag")
            }
            r.plus = 1
            i = i + 1
        } elif c == "-".char_at(0) {
            r.align = 1
            i = i + 1
        } elif c == "0".char_at(0) {
            r.zero = 1
            i = i + 1
        } else {
            break
        }
    }

    while i < spec.len() and sema_fmt_digit(spec.char_at(i)) {
        r.width = r.width * 10 + (spec.char_at(i) - 48)
        i = i + 1
    }
    if r.zero == 1 and r.width == 0 {
        r.fail(spec, "zero padding requires a width")
    }

    if i < spec.len() and spec.char_at(i) == ".".char_at(0) {
        i = i + 1
        start = i
        p = 0
        while i < spec.len() and sema_fmt_digit(spec.char_at(i)) {
            p = p * 10 + (spec.char_at(i) - 48)
            i = i + 1
        }
        if i == start {
            r.fail(spec, "precision requires digits")
        } else {
            r.precision = p
        }
    }

    if i < spec.len() {
        c = spec.char_at(i)
        if c == "d".char_at(0) {
            r.conv = 1
        } elif c == "x".char_at(0) {
            r.conv = 2
        } elif c == "X".char_at(0) {
            r.conv = 3
        } elif c == "o".char_at(0) {
            r.conv = 4
        } elif c == "b".char_at(0) {
            r.conv = 5
        } elif c == "f".char_at(0) {
            r.conv = 6
        } elif c == "e".char_at(0) {
            r.conv = 7
        } elif c == "E".char_at(0) {
            r.conv = 8
        } elif c == "g".char_at(0) {
            r.conv = 9
        } elif c == "G".char_at(0) {
            r.conv = 10
        } elif c == "s".char_at(0) {
            r.conv = 11
        } else {
            r.fail(spec, "unknown format type `" + spec.slice(i, i + 1) + "`")
        }
        i = i + 1
        if i < spec.len() {
            r.fail(spec, "unexpected character `" + spec.slice(i, i + 1) + "`")
        }
    }

    if not r.ok {
        return r
    }

    if str_eq(kind, "int") {
        if r.conv >= 6 and r.conv <= 11 {
            r.fail(spec, "integer format requires d/x/X/o/b")
        }
        if r.precision >= 0 {
            r.fail(spec, "precision is not supported for integers")
        }
        if r.alt == 1 and (r.conv == 0 or r.conv == 1) {
            r.fail(spec, "`#` requires x/X/o/b for integers")
        }
        if r.conv == 5 and r.plus == 1 {
            r.fail(spec, "`+` is not supported for binary")
        }
    } elif str_eq(kind, "float") {
        if r.conv != 0 and (r.conv < 6 or r.conv > 10) {
            r.fail(spec, "float format requires f/e/E/g/G")
        }
    } elif str_eq(kind, "bool") or str_eq(kind, "str") {
        if r.conv != 0 and r.conv != 11 {
            r.fail(spec, "only `s` is supported for strings")
        }
        if r.precision >= 0 and str_eq(kind, "bool") {
            r.fail(spec, "precision is not supported for bool")
        }
        if r.plus == 1 {
            r.fail(spec, "`+` is not supported for strings")
        }
        if r.alt == 1 {
            r.fail(spec, "`#` is not supported for strings")
        }
        if r.zero == 1 {
            r.fail(spec, "zero padding is not supported for strings")
        }
    } else {
        r.fail(spec, "unsupported argument type `" + kind + "`")
    }
    if r.zero == 1 and r.align == 3 {
        r.fail(spec, "zero padding cannot be combined with center alignment")
    }
    return r
}

# Build the C printf conversion for a parsed spec. `left` forces `-`, used by the IR
# generator when it applies padding itself (center alignment).
public def sema_format_printf_parts(kind: str, conv: int, plus: int, alt: int, zero: int,
                                    width: int, precision: int, left: int) -> str {
    fs = "%"
    if left == 1 {
        fs = fs + "-"
    }
    if plus == 1 {
        fs = fs + "+"
    }
    if alt == 1 {
        fs = fs + "#"
    }
    if zero == 1 {
        fs = fs + "0"
    }
    if width > 0 {
        fs = fs + to_string(width)
    }
    if precision >= 0 {
        fs = fs + "." + to_string(precision)
    }
    if str_eq(kind, "int") {
        if conv == 2 {
            return fs + "llx"
        }
        if conv == 3 {
            return fs + "llX"
        }
        if conv == 4 {
            return fs + "llo"
        }
        return fs + "lld"
    }
    if str_eq(kind, "float") {
        if conv == 6 {
            return fs + "f"
        }
        if conv == 7 {
            return fs + "e"
        }
        if conv == 8 {
            return fs + "E"
        }
        if conv == 9 {
            return fs + "g"
        }
        if conv == 10 {
            return fs + "G"
        }
        return fs + "g"
    }
    return fs + "s"
}

public def sema_format_printf(spec: str, kind: str) -> str {
    r = sema_format_spec_parse(spec, kind)
    left = 0
    if r.align == 1 {
        left = 1
    }
    zero = r.zero
    if r.align == 3 {
        zero = 0
    }
    return sema_format_printf_parts(kind, r.conv, r.plus, r.alt, zero, r.width, r.precision, left)
}

# Type annotation -> mangled type name.
#   int -> "int", Point -> "Point", List[int] -> "List$int",
#   Map[str,int] -> "Map$str$int", Maybe[int] -> "Maybe$int",
#   Result[int,str] -> "Result$int$str"
public def mangled_type_name(te: TypeExpr) -> str {
    if str_eq(te.name, "List") and te.args.len() == 1 {
        return "List$" + mangled_type_name(te.args.get(0))
    }
    if str_eq(te.name, "Map") and te.args.len() == 2 {
        return "Map$" + mangled_type_name(te.args.get(0)) + "$" + mangled_type_name(te.args.get(1))
    }
    if str_eq(te.name, "Maybe") and te.args.len() == 1 {
        return "Maybe$" + mangled_type_name(te.args.get(0))
    }
    if str_eq(te.name, "Result") and te.args.len() == 2 {
        return "Result$" + mangled_type_name(te.args.get(0)) + "$" + mangled_type_name(te.args.get(1))
    }
    if str_eq(te.name, "Task") and te.args.len() == 1 {
        return "Task$" + mangled_type_name(te.args.get(0))
    }
    return te.name
}

# Type annotation -> kind name ("int"/"float"/"bool"/"str"/"None"/"custom").
public def type_kind_of_te(te: TypeExpr) -> str {
    if str_eq(te.name, "List") or str_eq(te.name, "Map") or
       str_eq(te.name, "Maybe") or str_eq(te.name, "Result") {
        return "custom"
    }
    if str_eq(te.name, "int") { return "int" }
    if str_eq(te.name, "float") { return "float" }
    if str_eq(te.name, "bool") { return "bool" }
    if str_eq(te.name, "str") { return "str" }
    if str_eq(te.name, "None") { return "None" }
    if te.name.len() == 0 { return "None" }
    return "custom"
}

# LLVM type name.
public def llvm_type_of(kind: str, custom: str) -> str {
    if str_eq(kind, "int") { return "i64" }
    if str_eq(kind, "float") { return "double" }
    if str_eq(kind, "bool") { return "i1" }
    if str_eq(kind, "str") { return "ptr" }
    if str_eq(kind, "None") { return "i64" }
    if str_eq(kind, "custom") { return "%" + custom }
    return "i64"
}

# Type kind name -> LLVM type name.
public def llvm_type_of_kind(kind: str) -> str {
    return llvm_type_of(kind, "")
}

# The semantic analyzer.
public class Sema {
    # class registry
    class_order: List[str]
    class_fields: Map[str, str]        # class name -> "f1,f2"
    class_field_types: Map[str, str]   # class name -> "i64,ptr" (LLVM types)
    class_field_kinds: Map[str, str]   # class name -> "int,str" (kind names)
    class_methods: Map[str, str]       # class name -> "m1,m2"

    # function registry (top-level function names / Class$method)
    fn_order: List[str]
    fn_ret_llvm: Map[str, str]         # function name -> "i64"/"void"/...
    fn_ret_kinds: Map[str, str]        # function name -> "int"/.../"None"
    fn_ret_customs: Map[str, str]     # function name -> mangled custom type name ("" means scalar)
    fn_params_llvm: Map[str, str]      # function name -> "i64,ptr"
    fn_param_kinds: Map[str, str]      # function name -> "int,str"
    fn_param_customs: Map[str, str]    # function name -> "Point,List$int" (empty at scalar positions)
    fn_is_extern: Map[str, int]        # function name -> 1 = extern def (C ABI; type conversions at call sites)
    async_fns: Map[str, int]           # function name -> 1 = async def (calls return Task[T])

    # generic templates and instantiations
    generic_fns: Map[str, Stmt]
    generic_fn_names: List[str]
    generic_classes: Map[str, Stmt]
    generic_enums: Map[str, Stmt]
    extra_stmts: List[Stmt]
    type_env: Map[str, str]            # type parameter -> encoded type (custom starts with $)
    inst_envs: Map[str, str]           # instance name -> serialized type environment
    last_generic_custom: str

    # module context
    current_module: str
    private_fns: Map[str, str]
    class_modules: Map[str, str]
    class_publics: Map[str, int]

    # module-qualified calls: module.name -> internal function name; plus the set of loaded modules
    module_exports: Map[str, str]
    module_names: Map[str, int]
    qualified_calls: Map[str, str]

    # Bare-name call resolution: call-site key -> internal function name (including generic instances).
    # Sema resolves and records it during checking; the IR side emits the symbol from this, without re-deriving naming rules.
    call_syms: Map[str, str]
    # from-import scope: current module$alias -> "module.orig_name"
    from_imports: Map[str, str]
    # bare name -> module exporting that symbol (multiple exporters set the value to "\x01multi"; owner_list is for diagnostics)
    export_owners: Map[str, str]
    export_owner_list: Map[str, str]
    # bare type names (class/enum/interface) -> registered owner; multiple owners as above
    type_owners: Map[str, str]
    type_owner_list: Map[str, str]
    # type names declared by each module (module$bare -> 1, including generic templates; for forward references and resolution)
    module_types: Map[str, str]
    # registration key -> original source name (for diagnostics; does not expose the module$ physical name)
    type_orig: Map[str, str]
    # plain import binding: current module$bound name -> canonical module name (hierarchical paths bind the last segment)
    module_bindings: Map[str, str]
    # glob import scope: List["cur$module"] (Map has no iteration interface; use List + contains for deduplication)
    glob_imports: List[str]
    # type re-export: cur$alias -> src$type (the type chain of public from m import T, followed during resolution)
    type_reexports: Map[str, str]

    # interfaces and error deduplication
    iface_defs: Map[str, Stmt]
    class_interfaces: Map[str, str]
    enum_inst_errors: Map[str, int]
    class_inst_errors: Map[str, int]

    # enum registry
    enum_order: List[str]
    enum_variants: Map[str, str]        # enum name -> "V1,V2"
    enum_payloads: Map[str, int]       # enum name -> maximum payload slot count
    enum_variant_enum: Map[str, str]   # variant name -> enum name
    enum_variant_idx: Map[str, int]    # variant name -> variant index
    enum_field_kinds: Map[str, str]    # enum name -> "int,float|str" (variants separated by |)
    enum_field_names: Map[str, str]     # enum name -> "|w,h" (named-field patterns)

    # current function checking state
    cur_locals: Map[str, str]           # local variable name -> kind name
    cur_local_customs: Map[str, str]    # local variable name -> custom type name
    cur_fn_ret_kind: str
    cur_fn_ret_custom: str
    cur_fn_name: str
    cur_fn_async: int                   # whether the current function is async def
    loop_depth: int
    cur_moved: Map[str, int]            # whether a variable has been moved
    cur_borrow_shared: Map[str, int]    # shared borrow count
    cur_borrow_mut: Map[str, int]       # mutable borrow count
    cur_borrow_target: Map[str, str]    # borrow handle -> target variable
    cur_handle_mut: Map[str, int]       # whether the handle is a mutable borrow
    cur_var_names: List[str]            # declared variable names (for state snapshots)
    in_expr_stmt: int                   # 1 = checking a trailing expression in statement position
    cur_var_seen: Map[str, int]
    check_depth: int                    # recursion depth guard

    # diagnostics
    diag_source_name: str
    diag_source: str
    diag_items: List[DiagItem]
    diag_errors: int
}

public def make_sema() -> Sema {
    s = Sema()
    s.class_order = List[str]()
    s.class_fields = Map[str, str]()
    s.class_field_types = Map[str, str]()
    s.class_field_kinds = Map[str, str]()
    s.class_methods = Map[str, str]()
    s.fn_order = List[str]()
    s.fn_ret_llvm = Map[str, str]()
    s.fn_ret_kinds = Map[str, str]()
    s.fn_ret_customs = Map[str, str]()
    s.fn_params_llvm = Map[str, str]()
    s.fn_param_kinds = Map[str, str]()
    s.fn_param_customs = Map[str, str]()
    s.fn_is_extern = Map[str, int]()
    s.async_fns = Map[str, int]()
    s.generic_fns = Map[str, Stmt]()
    s.generic_fn_names = List[str]()
    s.generic_classes = Map[str, Stmt]()
    s.generic_enums = Map[str, Stmt]()
    s.extra_stmts = List[Stmt]()
    s.type_env = Map[str, str]()
    s.inst_envs = Map[str, str]()
    s.last_generic_custom = ""
    s.current_module = ""
    s.private_fns = Map[str, str]()
    s.class_modules = Map[str, str]()
    s.class_publics = Map[str, int]()
    s.module_exports = Map[str, str]()
    s.module_names = Map[str, int]()
    s.qualified_calls = Map[str, str]()
    s.call_syms = Map[str, str]()
    s.from_imports = Map[str, str]()
    s.export_owners = Map[str, str]()
    s.export_owner_list = Map[str, str]()
    s.type_owners = Map[str, str]()
    s.type_owner_list = Map[str, str]()
    s.module_types = Map[str, str]()
    s.type_orig = Map[str, str]()
    s.module_bindings = Map[str, str]()
    s.glob_imports = List[str]()
    s.type_reexports = Map[str, str]()
    s.iface_defs = Map[str, Stmt]()
    s.class_interfaces = Map[str, str]()
    s.enum_inst_errors = Map[str, int]()
    s.class_inst_errors = Map[str, int]()
    s.enum_order = List[str]()
    s.enum_variants = Map[str, str]()
    s.enum_payloads = Map[str, int]()
    s.enum_variant_enum = Map[str, str]()
    s.enum_variant_idx = Map[str, int]()
    s.enum_field_kinds = Map[str, str]()
    s.enum_field_names = Map[str, str]()
    s.cur_locals = Map[str, str]()
    s.cur_local_customs = Map[str, str]()
    s.cur_fn_ret_kind = "None"
    s.cur_fn_ret_custom = ""
    s.cur_fn_name = ""
    s.cur_fn_async = 0
    s.loop_depth = 0
    s.cur_moved = Map[str, int]()
    s.cur_borrow_shared = Map[str, int]()
    s.cur_borrow_mut = Map[str, int]()
    s.cur_borrow_target = Map[str, str]()
    s.cur_handle_mut = Map[str, int]()
    s.cur_var_names = List[str]()
    s.cur_var_seen = Map[str, int]()
    s.check_depth = 0
    s.in_expr_stmt = 0
    s.diag_source_name = ""
    s.diag_source = ""
    s.diag_items = make_diag_items()
    s.diag_errors = 0
    return s
}

# Unified error-code assignment for semantic diagnostics (v0.0.5).
# Every sema_error message maps to a stable code by matching its literal
# prefix/distinctive substring. Codes are documented in
# devdoc/RGC-0.0.5-ERRORCODES.md and grouped by category.
def sema_error_code_for_msg(msg: str) -> str {
    # ---- E03xx module system / visibility / ambiguity ----
    if msg.startswith("function `") and msg.contains(" is ambiguous:") { return "E0306" }
    if msg.startswith("type `") and msg.contains(" is ambiguous:") { return "E0307" }
    if msg.contains(" is private to module `") { return "E0305" }
    if msg.startswith("module binding ") { return "E0302" }
    if msg.startswith("cannot re-export private type") { return "E0303" }
    if msg.startswith("cannot re-export ") { return "E0304" }
    if msg.startswith("module `") and msg.contains(" has no public function") { return "E0308" }
    # ---- E04xx type errors ----
    if msg.startswith("type mismatch:") { return "E0401" }
    if msg.startswith("type `") and msg.contains(" redefined") { return "E0402" }
    if msg.startswith("duplicate interface") { return "E0403" }
    if msg.startswith("if branches have mismatched types:") { return "E0404" }
    if msg.contains(" returns `") and msg.contains("`, expected `") { return "E0405" }
    if msg.startswith("operator '+' cannot concatenate") { return "E0406" }
    if msg.startswith("cannot access member ") and msg.contains(" on non-class value") { return "E0407" }
    if msg.startswith("cannot access member ") and msg.contains(" on enum") { return "E0408" }
    if msg.startswith("unknown field ") { return "E0409" }
    # ---- E05xx expression name resolution ----
    if msg.startswith("use of undeclared variable") { return "E0501" }
    if msg.startswith("call to unknown function") { return "E0502" }
    # ---- E06xx ownership / move ----
    if msg.startswith("use of moved value:") { return "E0601" }
    if msg.startswith("cannot move out of ") { return "E0602" }
    # ---- E07xx borrow checker ----
    if msg.startswith("cannot borrow ") { return "E0701" }
    if msg.startswith("cannot access ") { return "E0702" }
    if msg.startswith("cannot use ") { return "E0702" }
    if msg.startswith("cannot assign through shared borrow") { return "E0703" }
    if msg.startswith("borrow target must be a variable") { return "E0704" }
    if msg.startswith("cannot copy a borrow handle") { return "E0705" }
    # ---- E08xx generics / interfaces ----
    if msg.startswith("type parameter ") and msg.contains(" inferred inconsistently") { return "E0801" }
    if msg.startswith("cannot infer type parameter") { return "E0802" }
    if msg.contains(" does not implement interface") and msg.contains(" missing method") { return "E0804" }
    if msg.contains(" does not match interface") { return "E0805" }
    if msg.startswith("unknown interface") { return "E0806" }
    if msg.contains(" is not a generic class") { return "E0807" }
    if msg.startswith("class `") and msg.contains(" expects ") and msg.contains(" type arguments") { return "E0808" }
    if msg.contains(" is not a generic enum") { return "E0809" }
    if msg.startswith("enum `") and msg.contains(" expects ") and msg.contains(" type arguments") { return "E0810" }
    if msg.contains(" does not implement interface") { return "E0803" }
    # ---- E10xx enum / match / patterns (variant-argument check first) ----
    if msg.contains(" to variant `") { return "E1002" }
    if msg.startswith("unknown variant ") { return "E1001" }
    if msg.startswith("match arms have mismatched types:") { return "E1003" }
    # ---- E11xx control flow ----
    if msg.startswith("`break` outside of a loop") { return "E1101" }
    if msg.startswith("`continue` outside of a loop") { return "E1102" }
    # ---- E12xx async / Task ----
    if msg.startswith("extern function ") and msg.contains(" cannot be async") { return "E1201" }
    if msg.startswith("async methods are not supported") { return "E1202" }
    if msg.startswith("`main` cannot be async;") { return "E1203" }
    if msg.startswith("async function ") and msg.contains(" cannot return a borrow") { return "E1204" }
    if msg.startswith("async function ") and msg.contains(" cannot take borrow parameter") { return "E1205" }
    if msg.startswith("`await` is only allowed inside an async function") { return "E1206" }
    if msg.startswith("`await` expects a Task value") { return "E1207" }
    if msg.startswith("asyncio.run() expects 1 argument") { return "E1208" }
    if msg.startswith("asyncio.run() expects a Task value") { return "E1209" }
    if msg.startswith("asyncio.cancelled() takes no arguments") { return "E1210" }
    if msg.startswith("cannot await ") { return "E1211" }
    if msg.startswith("cannot gather ") { return "E1212" }
    if msg.startswith("asyncio.gather() expects 1 argument") { return "E1213" }
    if msg.startswith("asyncio.gather() expects List[Task[T]]") { return "E1214" }
    if msg.startswith("asyncio.gather() does not support tasks without a value") { return "E1215" }
    if msg.startswith("asyncio.wait_any() expects 1 argument") { return "E1216" }
    if msg.startswith("asyncio.wait_any() expects List[Task[T]]") { return "E1217" }
    if msg.startswith("Task values can only be created") { return "E1218" }
    if msg.startswith("Task.wait() expects 1 argument (milliseconds)") { return "E1219" }
    if msg.startswith("Task.wait() expects int milliseconds") { return "E1220" }
    if msg.startswith("Task.") and msg.contains("() takes no arguments") { return "E1221" }
    # ---- E09xx function calls / arguments ----
    if msg.contains(" arguments, got ") { return "E0901" }
    if msg.startswith("argument ") and msg.contains(" has type ") { return "E0902" }
    # ---- E13xx format strings (must precede the generic builtin-arity check below) ----
    if msg.startswith("format() expects at least 1 argument") { return "E1301" }
    if msg.startswith("format() expects a string literal") { return "E1302" }
    if msg.startswith("unmatched `{` in format string") { return "E1303" }
    if msg.startswith("unmatched `}` in format string") { return "E1304" }
    if msg.startswith("format() expects ") and msg.contains(" placeholder argument(s)") { return "E1305" }
    if msg.startswith("format() argument must be int/float/bool/str") { return "E1306" }
    if msg.startswith("invalid format specifier `") { return "E1307" }
    # ---- E09xx builtin/method arity and argument kinds ----
    if msg.contains("() expects ") and msg.contains(" argument(s)") { return "E0903" }
    if msg.contains("() expects int/float, found") { return "E0904" }
    if msg.contains("() argument ") and msg.contains(" expects ") { return "E0905" }
    # ---- E14xx FFI / extern ----
    if msg.startswith("extern function ") and msg.contains(" cannot be generic") { return "E1401" }
    if msg.startswith("extern function ") and msg.contains(" return type must be") { return "E1402" }
    if msg.startswith("extern function ") and msg.contains(" parameter ") and msg.contains(" must be") { return "E1403" }
    # ---- E15xx builtins / stdlib methods ----
    if msg.contains("() is not supported for custom element type") { return "E1501" }
    if msg.startswith("to_string() expects 1 argument") { return "E1502" }
    if msg.startswith("to_string() expects int/float/bool") { return "E1503" }
    if msg.startswith("chr() expects 1 argument") { return "E1504" }
    if msg.startswith("chr() expects int, found") { return "E1505" }
    if msg.startswith("args() expects 0 arguments") { return "E1506" }
    if msg.startswith("range() can only be used as a for-loop iterable") { return "E1507" }
    if msg.startswith("range() expects 1 to 3 arguments") { return "E1508" }
    if msg.startswith("range() expects int, found") { return "E1509" }
    # ---- E16xx `?` operator / Result ----
    if msg.startswith("`?` requires a Result value") { return "E1601" }
    if msg.startswith("`?` can only be used in a function returning Result") { return "E1602" }
    if msg.startswith("`?` error type mismatch:") { return "E1603" }
    if msg.startswith("`?` does not support custom success payload") { return "E1604" }
    # Unclassified fallback (should not happen in practice).
    return "E0000"
}

public def sema_error(s: @var Sema, line: int, col: int, msg: str) {
    it = DiagItem()
    it.line = line
    it.col = col
    it.msg = msg
    it.code = sema_error_code_for_msg(msg)
    it.file = s.current_module
    s.diag_items.push(it)
    s.diag_errors = s.diag_errors + 1
}

# Register built-in standard-library functions (compiler builtins, no source).
# Branch state snapshots (stored in parallel by variable name).
public class SemaState {
    names: List[str]
    moved: List[int]
    shared: List[int]
    muts: List[int]
    handle_mut: List[int]
    targets: List[str]
}

# Type display name.
public def sema_type_name(kind: str, custom: str) -> str {
    if str_eq(kind, "custom") {
        return custom
    }
    return kind
}

public def sema_can_assign(fk: str, fc: str, tk: str, tc: str) -> bool {
    if str_eq(fk, "error") or str_eq(tk, "error") {
        return True
    }
    if str_eq(fk, tk) {
        if str_eq(fk, "custom") {
            return str_eq(fc, tc)
        }
        return True
    }
    if str_eq(fk, "int") and str_eq(tk, "float") {
        return True
    }
    return False
}

public def sema_reset_var_state(s: @var Sema) {
    s.cur_var_names = List[str]()
    s.cur_var_seen = Map[str, int]()
    s.cur_moved = Map[str, int]()
    s.cur_borrow_shared = Map[str, int]()
    s.cur_borrow_mut = Map[str, int]()
    s.cur_borrow_target = Map[str, str]()
    s.cur_handle_mut = Map[str, int]()
    s.loop_depth = 0
}

public def sema_mark_moved(s: @var Sema, name: str) {
    s.cur_moved.put(name, 1)
}

public def sema_is_moved(s: @var Sema, name: str) -> bool {
    return s.cur_moved.contains(name) and s.cur_moved.get(name) == 1
}

public def sema_shared_count(s: @var Sema, name: str) -> int {
    if s.cur_borrow_shared.contains(name) {
        return s.cur_borrow_shared.get(name)
    }
    return 0
}

public def sema_mut_count(s: @var Sema, name: str) -> int {
    if s.cur_borrow_mut.contains(name) {
        return s.cur_borrow_mut.get(name)
    }
    return 0
}

# Check moved / mutable-borrow state before reading a variable.
public def sema_check_use(s: @var Sema, name: str, line: int, col: int) {
    if sema_is_moved(s, name) {
        sema_error(s, line, col, "use of moved value: `" + name + "`")
        return
    }
    if sema_mut_count(s, name) > 0 {
        sema_error(s, line, col, "cannot access `" + name + "` because it is borrowed as @var")
        sema_error(s, line, col, "cannot use `" + name + "` because it is borrowed as @var")
    }
}

public def sema_register_builtins(s: @var Sema) {
    s.fn_ret_llvm.put("print", "void")
    s.fn_ret_kinds.put("print", "None")
    s.fn_ret_customs.put("print", "")
    s.fn_params_llvm.put("print", "")
    s.fn_param_kinds.put("print", "")
    s.fn_param_customs.put("print", "")

    s.fn_ret_llvm.put("to_string", "ptr")
    s.fn_ret_kinds.put("to_string", "str")
    s.fn_ret_customs.put("to_string", "")
    s.fn_params_llvm.put("to_string", "i64")
    s.fn_param_kinds.put("to_string", "int")
    s.fn_param_customs.put("to_string", "")

    s.fn_ret_llvm.put("chr", "ptr")
    s.fn_ret_kinds.put("chr", "str")
    s.fn_ret_customs.put("chr", "")
    s.fn_params_llvm.put("chr", "i64")
    s.fn_param_kinds.put("chr", "int")
    s.fn_param_customs.put("chr", "")

    s.fn_ret_llvm.put("args", "%List$str")
    s.fn_ret_kinds.put("args", "custom")
    s.fn_ret_customs.put("args", "List$str")
    s.fn_params_llvm.put("args", "")
    s.fn_param_kinds.put("args", "")
    s.fn_param_customs.put("args", "")

    s.fn_ret_llvm.put("system", "i64")
    s.fn_ret_kinds.put("system", "int")
    s.fn_ret_customs.put("system", "")
    s.fn_params_llvm.put("system", "ptr")
    s.fn_param_kinds.put("system", "str")
    s.fn_param_customs.put("system", "")

    s.fn_ret_llvm.put("read_file", "%Result$str$str")
    s.fn_ret_kinds.put("read_file", "custom")
    s.fn_ret_customs.put("read_file", "Result$str$str")
    s.fn_params_llvm.put("read_file", "ptr")
    s.fn_param_kinds.put("read_file", "str")
    s.fn_param_customs.put("read_file", "")

    s.fn_ret_llvm.put("write_file", "%Result$None$str")
    s.fn_ret_kinds.put("write_file", "custom")
    s.fn_ret_customs.put("write_file", "Result$None$str")
    s.fn_params_llvm.put("write_file", "ptr,ptr")
    s.fn_param_kinds.put("write_file", "str,str")
    s.fn_param_customs.put("write_file", "")

    s.fn_ret_llvm.put("range", "%List$int")
    s.fn_ret_kinds.put("range", "custom")
    s.fn_ret_customs.put("range", "List$int")
    s.fn_params_llvm.put("range", "i64")
    s.fn_param_kinds.put("range", "int")
    s.fn_param_customs.put("range", "")

    s.fn_ret_llvm.put("emit_object", "i64")
    s.fn_ret_kinds.put("emit_object", "int")
    s.fn_ret_customs.put("emit_object", "")
    s.fn_params_llvm.put("emit_object", "ptr,ptr")
    s.fn_param_kinds.put("emit_object", "str,str")
    s.fn_param_customs.put("emit_object", "")

    s.fn_ret_llvm.put("write_stderr", "void")
    s.fn_ret_kinds.put("write_stderr", "None")
    s.fn_ret_customs.put("write_stderr", "")
    s.fn_params_llvm.put("write_stderr", "ptr")
    s.fn_param_kinds.put("write_stderr", "str")
    s.fn_param_customs.put("write_stderr", "")

    s.fn_ret_llvm.put("remove_file", "%Result$None$str")
    s.fn_ret_kinds.put("remove_file", "custom")
    s.fn_ret_customs.put("remove_file", "Result$None$str")
    s.fn_params_llvm.put("remove_file", "ptr")
    s.fn_param_kinds.put("remove_file", "str")
    s.fn_param_customs.put("remove_file", "")

    s.fn_ret_llvm.put("append_file", "%Result$None$str")
    s.fn_ret_kinds.put("append_file", "custom")
    s.fn_ret_customs.put("append_file", "Result$None$str")
    s.fn_params_llvm.put("append_file", "ptr,ptr")
    s.fn_param_kinds.put("append_file", "str,str")
    s.fn_param_customs.put("append_file", "")

    s.fn_ret_llvm.put("exists", "i1")
    s.fn_ret_kinds.put("exists", "bool")
    s.fn_ret_customs.put("exists", "")
    s.fn_params_llvm.put("exists", "ptr")
    s.fn_param_kinds.put("exists", "str")
    s.fn_param_customs.put("exists", "")

    s.fn_ret_llvm.put("str_to_float", "double")
    s.fn_ret_kinds.put("str_to_float", "float")
    s.fn_ret_customs.put("str_to_float", "")
    s.fn_params_llvm.put("str_to_float", "ptr")
    s.fn_param_kinds.put("str_to_float", "str")
    s.fn_param_customs.put("str_to_float", "")

    # Virtual stdlib modules time / random / os / asyncio: qualified-name calls generate libc calls directly in IR.
    sema_reg_builtin_fn(s, "time.now_monotonic", "double", "float", "", "", "", "")
    sema_reg_builtin_fn(s, "time.monotonic_ms", "i64", "int", "", "", "", "")
    sema_reg_builtin_fn(s, "time.now", "i64", "int", "", "", "", "")
    sema_reg_builtin_fn(s, "time.sleep", "void", "None", "", "double", "float", "")
    sema_reg_builtin_fn(s, "random.seed", "void", "None", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "random.random_int", "i64", "int", "", "i64,i64", "int,int", "")
    sema_reg_builtin_fn(s, "random.random_float", "double", "float", "", "", "", "")
    sema_reg_builtin_fn(s, "os.exit", "void", "None", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "os.getenv", "%Maybe$str", "custom", "Maybe$str", "ptr", "str", "")
    sema_reg_builtin_fn(s, "os.setenv", "void", "None", "", "ptr,ptr", "str,str", "")
    sema_reg_builtin_fn(s, "os.getcwd", "%Result$str$str", "custom", "Result$str$str", "", "", "")

    # TCP primitives (wrapped by the standard library's net module; addr is a host-order IPv4 integer).
    sema_reg_builtin_fn(s, "tcp_connect", "i64", "int", "", "i64,i64", "int,int", "")
    sema_reg_builtin_fn(s, "tcp_listen", "i64", "int", "", "i64,i64,i64", "int,int,int", "")
    sema_reg_builtin_fn(s, "tcp_accept", "i64", "int", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "tcp_send", "i64", "int", "", "i64,ptr", "int,str", "")
    sema_reg_builtin_fn(s, "tcp_recv", "ptr", "str", "", "i64,i64", "int,int", "")
    sema_reg_builtin_fn(s, "tcp_close", "void", "None", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "tcp_local_port", "i64", "int", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "tcp_resolve", "i64", "int", "", "ptr", "str", "")
    sema_reg_builtin_fn(s, "tcp_error", "ptr", "str", "", "", "", "")
    # Raw sockaddr calls: let lib/net.rg connect/bind/listen directly with getaddrinfo results.
    sema_reg_builtin_fn(s, "tcp_connect_fd", "i64", "int", "", "i64,ptr,i64", "int,str,int", "")
    sema_reg_builtin_fn(s, "tcp_bind_fd", "i64", "int", "", "i64,ptr,i64", "int,str,int", "")
    sema_reg_builtin_fn(s, "tcp_listen_fd", "i64", "int", "", "i64,i64", "int,int", "")

    # Byte buffers / raw-pointer builtins: binary-safe data and FFI struct operations.
    sema_reg_builtin_fn(s, "buf_alloc", "ptr", "str", "", "i64", "int", "")
    sema_reg_builtin_fn(s, "buf_realloc", "ptr", "str", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "buf_free", "void", "None", "", "ptr", "str", "")
    sema_reg_builtin_fn(s, "buf_zero", "void", "None", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "buf_copy", "void", "None", "", "ptr,i64,ptr,i64,i64", "str,int,str,int,int", "")
    sema_reg_builtin_fn(s, "buf_get8", "i64", "int", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "buf_set8", "void", "None", "", "ptr,i64,i64", "str,int,int", "")
    sema_reg_builtin_fn(s, "buf_get32", "i64", "int", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "buf_set32", "void", "None", "", "ptr,i64,i64", "str,int,int", "")
    sema_reg_builtin_fn(s, "buf_get64", "i64", "int", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "buf_set64", "void", "None", "", "ptr,i64,i64", "str,int,int", "")
    sema_reg_builtin_fn(s, "buf_to_str", "ptr", "str", "", "ptr,i64", "str,int", "")
    sema_reg_builtin_fn(s, "ptr_null", "ptr", "str", "", "", "", "")
    sema_reg_builtin_fn(s, "ptr_is_null", "i1", "bool", "", "ptr", "str", "")
    sema_reg_builtin_fn(s, "ptr_to_int", "i64", "int", "", "ptr", "str", "")
    sema_reg_builtin_fn(s, "int_to_ptr", "ptr", "str", "", "i64", "int", "")

    # Built-in Task[T]: the result of calling an async function. Only the compiler constructs it;
    # the handle stores a pointer to the heap-allocated task box (tid + payload).
    task_tmpl = new_stmt(StmtClassDef(), 0, 0)
    task_tmpl.name = "Task"
    task_tmpl.type_params = list1_str("T")
    task_tmpl.fields = list1_field_decl(make_field("handle", type_expr("int")))
    s.generic_classes.put("Task", task_tmpl)
}

public def sema_reg_builtin_fn(s: @var Sema, name: str, ret_llvm: str, ret_kind: str,
                        ret_custom: str, params_llvm: str, param_kinds: str,
                        param_customs: str) {
    s.fn_ret_llvm.put(name, ret_llvm)
    s.fn_ret_kinds.put(name, ret_kind)
    s.fn_ret_customs.put(name, ret_custom)
    s.fn_params_llvm.put(name, params_llvm)
    s.fn_param_kinds.put(name, param_kinds)
    s.fn_param_customs.put(name, param_customs)
}

# Automatically register the layouts of built-in enums Maybe$X / Result$X,Y.
public def sema_register_builtin_enum(s: @var Sema, name: str) {
    if s.enum_variants.contains(name) {
        return
    }
    if name.startswith("Maybe$") {
        s.enum_order.push(name)
        s.enum_variants.put(name, "Some,Nothing")
        s.enum_payloads.put(name, 1)
        s.enum_variant_enum.put("Some", name)
        s.enum_variant_idx.put("Some", 0)
        s.enum_variant_enum.put("Nothing", name)
        s.enum_variant_idx.put("Nothing", 1)
        # payload kind: Some carries the first type parameter (scalar or str).
        payload = name.slice(6, name.len())
        s.enum_field_kinds.put(name, payload)
        s.enum_field_names.put(name, "v|")
    } elif name.startswith("Result$") {
        s.enum_order.push(name)
        s.enum_variants.put(name, "Ok,Err")
        s.enum_payloads.put(name, 1)
        s.enum_variant_enum.put("Ok", name)
        s.enum_variant_idx.put("Ok", 0)
        s.enum_variant_enum.put("Err", name)
        s.enum_variant_idx.put("Err", 1)
        rest = name.slice(7, name.len())
        d = str_find(rest, "$")
        ok_kind = rest.slice(0, d)
        err_kind = rest.slice(d + 1, rest.len())
        s.enum_field_kinds.put(name, ok_kind + "|" + err_kind)
        s.enum_field_names.put(name, "v|e")
    }
}

# Register class definitions.
# ---------- generic type substitution and instantiation ----------

public def sema_env_display(v: str) -> str {
    if v.startswith("$") {
        return v.slice(1, v.len())
    }
    return v
}

public def sema_env_kind(v: str) -> str {
    if v.startswith("$") {
        return "custom"
    }
    return v
}

public def sema_env_custom(v: str) -> str {
    if v.startswith("$") {
        return v.slice(1, v.len())
    }
    return ""
}

public def sema_encode_kind(kind: str, custom: str) -> str {
    if str_eq(kind, "custom") {
        return "$" + custom
    }
    return kind
}

# ---------- async task types ----------

# The result type of calling an async function: Task$<payload mangled name>.
public def sema_task_type(kind: str, custom: str) -> str {
    if str_eq(kind, "custom") {
        return "Task$" + custom
    }
    return "Task$" + kind
}

# Task$T -> T (returns an empty string when not a Task).
public def sema_task_payload(task: str) -> str {
    if task.startswith("Task$") {
        return task.slice(5, task.len())
    }
    return ""
}

# Payload mangled name -> kind name.
public def sema_payload_kind(payload: str) -> str {
    if str_eq(payload, "int") { return "int" }
    if str_eq(payload, "float") { return "float" }
    if str_eq(payload, "bool") { return "bool" }
    if str_eq(payload, "str") { return "str" }
    if str_eq(payload, "None") { return "None" }
    return "custom"
}

public def sema_task_payload_custom(task: str) -> str {
    p = sema_task_payload(task)
    if str_eq(sema_payload_kind(p), "custom") {
        return p
    }
    return ""
}

# Instantiate the built-in Task[T] (by payload type) and return Task$T.
public def sema_async_task(s: @var Sema, kind: str, custom: str,
                           line: int, col: int) -> str {
    encs = List[str]()
    encs.push(sema_encode_kind(kind, custom))
    return sema_instantiate_class(s, "Task", encs, line, col)
}

public def sema_async_task_of_fn(s: @var Sema, fn_key: str,
                                 line: int, col: int) -> str {
    return sema_async_task(s, s.fn_ret_kinds.get(fn_key),
                           s.fn_ret_customs.get(fn_key), line, col)
}

public def sema_apply_env_string(s: @var Sema, envstr: str) {
    s.type_env = Map[str, str]()
    if envstr.len() == 0 {
        return
    }
    parts = envstr.split(";")
    i = 0
    while i < parts.len() {
        part = parts.get(i)
        if part.len() > 0 {
            eq = str_find(part, "=")
            if eq >= 0 {
                s.type_env.put(part.slice(0, eq), part.slice(eq + 1, part.len()))
            }
        }
        i = i + 1
    }
}

public def sema_subst_te(s: @var Sema, te: TypeExpr) -> TypeExpr {
    if te.args.len() == 0 and s.type_env.contains(te.name) {
        v = s.type_env.get(te.name)
        t = type_expr_at(sema_env_display(v), te.line, te.col)
        t.is_borrow = te.is_borrow
        t.is_mut_borrow = te.is_mut_borrow
        return t
    }
    if te.args.len() > 0 {
        args = List[TypeExpr]()
        i = 0
        while i < te.args.len() {
            args.push(sema_subst_te(s, te.args.get(i)))
            i = i + 1
        }
        t = type_apply_at(te.name, args, te.line, te.col)
        t.is_borrow = te.is_borrow
        t.is_mut_borrow = te.is_mut_borrow
        return t
    }
    return te
}

public def sema_encode_type(s: @var Sema, te: TypeExpr) -> str {
    if te.args.len() == 0 and s.type_env.contains(te.name) {
        return s.type_env.get(te.name)
    }
    if te.args.len() > 0 {
        # Custom generic classes/enums: resolve the module namespace first, then instantiate by registration key.
        if s.generic_classes.len() > 0 or s.generic_enums.len() > 0 {
            tkey = sema_resolve_type_key(s, te.name, te.line, te.col)
        } else {
            tkey = te.name
        }
        if s.generic_classes.contains(tkey) {
            encs = List[str]()
            i = 0
            while i < te.args.len() {
                at = te.args.get(i)
                encs.push(sema_encode_type(s, at))
                i = i + 1
            }
            return "$" + sema_instantiate_class(s, tkey, encs, te.line, te.col)
        }
        if s.generic_enums.contains(tkey) {
            encs = List[str]()
            i = 0
            while i < te.args.len() {
                at = te.args.get(i)
                encs.push(sema_encode_type(s, at))
                i = i + 1
            }
            return "$" + sema_instantiate_enum(s, te.name, encs, te.line, te.col)
        }
        if str_eq(te.name, "List") {
            at = te.args.get(0)
            return "$List$" + sema_env_display(sema_encode_type(s, at))
        }
        if str_eq(te.name, "Map") {
            a0 = te.args.get(0)
            a1 = te.args.get(1)
            return "$Map$" + sema_env_display(sema_encode_type(s, a0)) + "$" +
                   sema_env_display(sema_encode_type(s, a1))
        }
        if str_eq(te.name, "Maybe") {
            at = te.args.get(0)
            return "$Maybe$" + sema_env_display(sema_encode_type(s, at))
        }
        if str_eq(te.name, "Result") {
            a0 = te.args.get(0)
            a1 = te.args.get(1)
            return "$Result$" + sema_env_display(sema_encode_type(s, a0)) + "$" +
                   sema_env_display(sema_encode_type(s, a1))
        }
        out = te.name
        i = 0
        while i < te.args.len() {
            at = te.args.get(i)
            out = out + "$" + sema_env_display(sema_encode_type(s, at))
            i = i + 1
        }
        return "$" + out
    }
    if te.name.len() == 0 {
        return "None"
    }
    if str_eq(te.name, "int") or str_eq(te.name, "float") or
       str_eq(te.name, "bool") or str_eq(te.name, "str") or
       str_eq(te.name, "None") {
        return te.name
    }
    # Custom types: resolve the module namespace, then encode by registration key.
    rkey = sema_resolve_type_key(s, te.name, te.line, te.col)
    return "$" + rkey
}

public def sema_te_kind(s: @var Sema, te: TypeExpr) -> str {
    return sema_env_kind(sema_encode_type(s, te))
}

public def sema_te_mangled(s: @var Sema, te: TypeExpr) -> str {
    return sema_env_display(sema_encode_type(s, te))
}

public def sema_env_string(tparams: List[str], encs: List[str]) -> str {
    out = ""
    i = 0
    while i < tparams.len() and i < encs.len() {
        out = out + tparams.get(i) + "=" + encs.get(i) + ";"
        i = i + 1
    }
    return out
}

public def sema_register_interface(s: @var Sema, st: Stmt) {
    if s.iface_defs.contains(st.name) {
        sema_error(s, st.line, st.col, "duplicate interface `" + st.name + "`")
        return
    }
    s.iface_defs.put(st.name, st)
}

public def sema_fn_key(s: @var Sema, name: str) -> str {
    if s.current_module.len() > 0 {
        key = s.current_module + "$" + name
        if s.fn_ret_kinds.contains(key) {
            return key
        }
    }
    if s.fn_ret_kinds.contains(name) {
        return name
    }
    return ""
}

# ---------- module namespace resolution ----------
#
# Registration phase: top-level module symbols are physically registered as module$name (the entry file keeps bare names);
# Reference phase: bare names resolve along a fixed chain — local declarations -> from-import -> bare name (entry/builtin)
#         -> the unique exporter -> ambiguity error. Same-named symbols across modules therefore never collide.

# Record "bare name -> module exporting the function"; mark ambiguity when a second exporter appears.
public def sema_record_export(s: @var Sema, mod: str, name: str) {
    prev = ""
    if s.export_owners.contains(name) {
        prev = s.export_owners.get(name)
    }
    if prev.len() > 0 and not str_eq(prev, mod) and not str_eq(prev, "<multi>") {
        s.export_owners.put(name, "<multi>")
        s.export_owner_list.put(name, s.export_owner_list.get(name) + ", " + mod)
        return
    }
    if prev.len() == 0 {
        s.export_owners.put(name, mod)
        s.export_owner_list.put(name, mod)
    }
}

# Record "bare name -> module defining the type"; same-named types across modules are registered per-module and reported ambiguously at use sites.
public def sema_record_type_owner(s: @var Sema, mod: str, name: str) {
    prev = ""
    if s.type_owners.contains(name) {
        prev = s.type_owners.get(name)
    }
    if prev.len() > 0 and not str_eq(prev, mod) and not str_eq(prev, "<multi>") {
        s.type_owners.put(name, "<multi>")
        s.type_owner_list.put(name, s.type_owner_list.get(name) + ", " + mod)
        return
    }
    if prev.len() == 0 {
        s.type_owners.put(name, mod)
        s.type_owner_list.put(name, mod)
    }
}

# Type display name for diagnostics: restore the original source name from the registration key.
public def sema_type_display(s: @var Sema, key: str) -> str {
    if s.type_orig.contains(key) {
        return s.type_orig.get(key)
    }
    return key
}

# Whether the type is registered (including generic templates).
public def sema_type_registered(s: @var Sema, key: str) -> bool {
    return s.class_fields.contains(key) or s.enum_field_kinds.contains(key) or
           s.iface_defs.contains(key) or s.generic_classes.contains(key) or
           s.generic_enums.contains(key)
}

# Plain import binding lookup: bound name -> canonical module name; falls back to the original name when unbound.
public def sema_module_canonical(s: @var Sema, bound: str) -> str {
    key = s.current_module + "$" + bound
    if s.module_bindings.contains(key) {
        return s.module_bindings.get(key)
    }
    return bound
}

# Function candidates for glob imports: only public symbols (module_exports / public generic templates).
# Returns the unique target; "" when there are no candidates; after an ambiguity error with multiple candidates, also "".
public def sema_glob_fn(s: @var Sema, name: str, line: int, col: int) -> str {
    if s.glob_imports.len() == 0 {
        return ""
    }
    prefix = s.current_module + "$"
    found = ""
    owners = ""
    count = 0
    i = 0
    while i < s.glob_imports.len() {
        gkey = s.glob_imports.get(i)
        if gkey.startswith(prefix) {
            mod = gkey.slice(prefix.len(), gkey.len())
            cand = ""
            ek = mod + "." + name
            if s.module_exports.contains(ek) {
                cand = s.module_exports.get(ek)
            } elif s.generic_fns.contains(mod + "$" + name) {
                priv = s.private_fns.contains(name) and str_eq(s.private_fns.get(name), mod)
                if not priv {
                    cand = mod + "$" + name
                }
            }
            if cand.len() > 0 {
                if count == 0 {
                    found = cand
                    owners = mod
                } elif count == 1 {
                    owners = owners + ", " + mod
                }
                count = count + 1
            }
        }
        i = i + 1
    }
    if count > 1 {
        sema_error(s, line, col, "function `" + name + "` is ambiguous: exported by modules " +
                   owners + " (qualify as `<module>." + name + "`)")
        return ""
    }
    return found
}

# Type candidates for glob imports: module_types (including generic templates); privacy is checked at use sites.
public def sema_glob_type(s: @var Sema, name: str, line: int, col: int) -> str {
    if s.glob_imports.len() == 0 {
        return ""
    }
    prefix = s.current_module + "$"
    found = ""
    owners = ""
    count = 0
    i = 0
    while i < s.glob_imports.len() {
        gkey = s.glob_imports.get(i)
        if gkey.startswith(prefix) {
            mod = gkey.slice(prefix.len(), gkey.len())
            tkey = mod + "$" + name
            if s.module_types.contains(tkey) {
                if count == 0 {
                    found = tkey
                    owners = mod
                } elif count == 1 {
                    owners = owners + ", " + mod
                }
                count = count + 1
            }
        }
        i = i + 1
    }
    if count > 1 {
        sema_error(s, line, col, "type `" + name + "` is ambiguous: defined in modules " +
                   owners + " (qualify with `from <module> import " + name + "`)")
        return ""
    }
    return found
}

# from-import lookup: current scope$alias -> "module.orig_name"; returns "" when there is no import.
public def sema_from_lookup(s: @var Sema, name: str) -> str {
    if s.from_imports.len() == 0 {
        return ""
    }
    key = s.current_module + "$" + name
    if s.from_imports.contains(key) {
        return s.from_imports.get(key)
    }
    return ""
}

# Type resolution: source bare name -> registration key. On failure returns the original name (backward compatible for entry types / built-in enums).
public def sema_resolve_type_key(s: @var Sema, name: str, line: int, col: int) -> str {
    if name.len() == 0 {
        return name
    }
    # 0. types declared in this module (including forward references within the module)
    if s.current_module.len() > 0 {
        key = s.current_module + "$" + name
        if s.module_types.contains(key) {
            return key
        }
    }
    # 1. from-import: module.orig -> module$orig (follow re-export chains step by step)
    fk = sema_from_lookup(s, name)
    if fk.len() > 0 {
        parts = fk.split(".")
        if parts.len() == 2 {
            tkey = parts.get(0) + "$" + parts.get(1)
            depth = 0
            while not sema_type_registered(s, tkey) and s.type_reexports.contains(tkey) and depth < 8 {
                tkey = s.type_reexports.get(tkey)
                depth = depth + 1
            }
            if sema_type_registered(s, tkey) {
                return tkey
            }
        }
    }
    # 2. bare name (entry types / built-in enums)
    if sema_type_registered(s, name) {
        return name
    }
    # 2.5 glob import: unique candidate (ambiguity is reported inside the helper)
    gt = sema_glob_type(s, name, line, col)
    if gt.len() > 0 {
        return gt
    }
    # 3. unique owner; multiple owners report ambiguity at the use site
    if s.type_owners.contains(name) {
        owner = s.type_owners.get(name)
        if str_eq(owner, "<multi>") {
            sema_error(s, line, col, "type `" + name + "` is ambiguous: defined in modules " +
                       s.type_owner_list.get(name) +
                       " (qualify with `from <module> import " + name + "`)")
            return ""
        }
        tkey2 = owner + "$" + name
        if sema_type_registered(s, tkey2) {
            return tkey2
        }
    }
    return name
}

# Function/generic-template resolution: bare name -> physical symbol name. Reports ambiguity and returns "" on error.
# The result may be a concrete function (fn_ret_kinds) or a generic template key (generic_fns); callers handle each.
public def sema_resolve_fn_key(s: @var Sema, name: str, line: int, col: int) -> str {
    if name.len() == 0 {
        return ""
    }
    # 0. this module
    if s.current_module.len() > 0 {
        key = s.current_module + "$" + name
        if s.fn_ret_kinds.contains(key) or s.generic_fns.contains(key) {
            return key
        }
    }
    # 1. from-import:module.orig
    fk = sema_from_lookup(s, name)
    if fk.len() > 0 {
        if s.module_exports.contains(fk) {
            return s.module_exports.get(fk)
        }
        parts = fk.split(".")
        if parts.len() == 2 {
            tkey = parts.get(0) + "$" + parts.get(1)
            if s.generic_fns.contains(tkey) {
                return tkey
            }
        }
    }
    # 2. bare name (entry functions / builtins / extern)
    if s.fn_ret_kinds.contains(name) or s.generic_fns.contains(name) {
        return name
    }
    # 2.5 glob import: unique public candidate (ambiguity is reported inside the helper)
    gk = sema_glob_fn(s, name, line, col)
    if gk.len() > 0 {
        return gk
    }
    # 3. unique exporter
    if s.export_owners.contains(name) {
        owner = s.export_owners.get(name)
        if str_eq(owner, "<multi>") {
            sema_error(s, line, col, "function `" + name + "` is ambiguous: exported by modules " +
                       s.export_owner_list.get(name) +
                       " (qualify as `<module>." + name + "`)")
            return ""
        }
        ckey = owner + "$" + name
        if s.fn_ret_kinds.contains(ckey) or s.generic_fns.contains(ckey) {
            return ckey
        }
    }
    return ""
}

# Qualified aliases of built-in virtual modules (io.read_file still works when io has no source file).
public def sema_is_math_builtin(name: str) -> bool {
    return str_eq(name, "abs") or str_eq(name, "min") or str_eq(name, "max") or
           str_eq(name, "sqrt") or str_eq(name, "pow") or
           str_eq(name, "floor") or str_eq(name, "ceil")
}

public def sema_is_num_kind(k: str) -> bool {
    return str_eq(k, "int") or str_eq(k, "float")
}

public def sema_module_builtin_alias(module: str, name: str) -> str {
    if str_eq(module, "io") {
        if str_eq(name, "read_file") { return "read_file" }
        if str_eq(name, "write_file") { return "write_file" }
        if str_eq(name, "append_file") { return "append_file" }
        if str_eq(name, "exists") { return "exists" }
        if str_eq(name, "remove_file") { return "remove_file" }
    }
    if str_eq(module, "math") and sema_is_math_builtin(name) {
        return "math." + name
    }
    if str_eq(module, "time") {
        if str_eq(name, "now_monotonic") { return "time.now_monotonic" }
        if str_eq(name, "monotonic_ms") { return "time.monotonic_ms" }
        if str_eq(name, "now") { return "time.now" }
        if str_eq(name, "sleep") { return "time.sleep" }
    }
    if str_eq(module, "random") {
        if str_eq(name, "seed") { return "random.seed" }
        if str_eq(name, "random_int") { return "random.random_int" }
        if str_eq(name, "random_float") { return "random.random_float" }
    }
    if str_eq(module, "os") {
        if str_eq(name, "exit") { return "os.exit" }
        if str_eq(name, "getenv") { return "os.getenv" }
        if str_eq(name, "setenv") { return "os.setenv" }
        if str_eq(name, "getcwd") { return "os.getcwd" }
        if str_eq(name, "system") { return "system" }
    }
    if str_eq(module, "asyncio") {
        if str_eq(name, "run") { return "asyncio.run" }
        if str_eq(name, "gather") { return "asyncio.gather" }
        if str_eq(name, "wait_any") { return "asyncio.wait_any" }
        if str_eq(name, "cancelled") { return "asyncio.cancelled" }
    }
    return ""
}

# Call-site key: module prefix + line:col. Calls at the same position in different modules must be treated as different call sites.
public def sema_call_key(s: @var Sema, e: @Expr) -> str {
    return s.current_module + "$" + expr_call_key(e)
}

public def sema_qualified_name(s: @var Sema, e: @Expr) -> str {
    key = sema_call_key(s, e)
    if s.qualified_calls.contains(key) {
        return s.qualified_calls.get(key)
    }
    return ""
}

public def sema_check_type_visibility(s: @var Sema, name: str, line: int, col: int) {
    name = sema_resolve_type_key(s, name, line, col)
    if not s.class_modules.contains(name) {
        return
    }
    owner = s.class_modules.get(name)
    pub = s.class_publics.get(name)
    if owner.len() > 0 and pub == 0 and not str_eq(s.current_module, owner) {
        sema_error(s, line, col, "symbol `" + sema_type_display(s, name) +
                   "` is private to module `" + owner + "`")
    }
}

public def sema_type_implements(s: @var Sema, enc: str, iface: str) -> bool {
    if not str_eq(sema_env_kind(enc), "custom") {
        return False
    }
    cls = sema_env_custom(enc)
    if not s.class_interfaces.contains(cls) {
        return False
    }
    names = s.class_interfaces.get(cls).split(",")
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), iface) {
            return True
        }
        i = i + 1
    }
    return False
}

public def sema_check_interfaces(s: @var Sema, c: Stmt) {
    if not s.class_interfaces.contains(c.name) {
        return
    }
    names = s.class_interfaces.get(c.name).split(",")
    ni = 0
    while ni < names.len() {
        iname = names.get(ni)
        if iname.len() == 0 {
            ni = ni + 1
            continue
        }
        if not s.iface_defs.contains(iname) {
            sema_error(s, c.line, c.col, "unknown interface `" + iname + "`")
            ni = ni + 1
            continue
        }
        iface = s.iface_defs.get(iname)
        mi = 0
        while mi < iface.methods.len() {
            im = iface.methods.get(mi)
            found = False
            cm = new_stmt(StmtFnDef(), c.line, c.col)
            ci = 0
            while ci < c.methods.len() {
                cand = c.methods.get(ci)
                if str_eq(cand.name, im.name) {
                    found = True
                    cm = cand
                }
                ci = ci + 1
            }
            if not found {
                sema_error(s, c.line, c.col, "class `" + c.name +
                           "` does not implement interface `" + iname +
                           "`: missing method `" + im.name + "`")
            } else {
                icount = im.params.len()
                if icount > 0 {
                    icount = icount - 1
                }
                ccount = cm.params.len()
                if ccount > 0 {
                    ccount = ccount - 1
                }
                ienc = sema_encode_type(s, im.ret_type)
                cenc = sema_encode_type(s, cm.ret_type)
                if not str_eq(ienc, cenc) or icount != ccount {
                    sema_error(s, c.line, c.col, "method `" + im.name +
                               "` of class `" + c.name + "` does not match interface `" +
                               iname + "` signature")
                }
            }
            mi = mi + 1
        }
        ni = ni + 1
    }
}

public def sema_check_enum_variant_args(s: @var Sema, e: @Expr, enum_name: str) {
    v_idx = sema_match_variant_idx(s, enum_name, e.name)
    if v_idx < 0 {
        sema_error(s, e.line, e.col, "unknown variant `" + e.name +
                   "` of enum `" + enum_name + "`")
        return
    }
    if not s.enum_field_kinds.contains(enum_name) {
        return
    }
    kinds_all = s.enum_field_kinds.get(enum_name).split("|")
    fkinds = List[str]()
    if v_idx < kinds_all.len() {
        fkinds = kinds_all.get(v_idx).split(",")
    }
    i = 0
    while i < e.args.len() and i < fkinds.len() {
        ak = sema_check_expr(s, e.args.get(i))
        ac = sema_expr_custom(s, e.args.get(i))
        ek = fkinds.get(i)
        if ek.len() > 0 and not sema_can_assign(ak, ac, ek, "") {
            sema_error(s, e.args.get(i).line, e.args.get(i).col,
                       "argument " + to_string(i + 1) +
                       " to variant `" + e.name + "` has type `" +
                       sema_type_name(ak, ac) + "`, expected `" + ek + "`")
        }
        i = i + 1
    }
}

public def sema_instantiate_class(s: @var Sema, name: str, encs: List[str],
                           line: int, col: int) -> str {
    if not s.generic_classes.contains(name) {
        sema_error(s, line, col, "`" + sema_type_display(s, name) + "` is not a generic class")
        return ""
    }
    tmpl = s.generic_classes.get(name)
    if encs.len() != tmpl.type_params.len() {
        key = name + "#count#" + to_string(encs.len())
        if not s.class_inst_errors.contains(key) {
            s.class_inst_errors.put(key, 1)
            sema_error(s, line, col, "class `" + sema_type_display(s, name) + "` expects " +
                       to_string(tmpl.type_params.len()) + " type arguments, got " +
                       to_string(encs.len()))
        }
        return ""
    }
    inst_name = name
    i = 0
    while i < encs.len() {
        inst_name = inst_name + "$" + sema_env_display(encs.get(i))
        i = i + 1
    }
    if s.class_fields.contains(inst_name) {
        return inst_name
    }
    if s.class_inst_errors.contains(inst_name) {
        return ""
    }
    i = 0
    while i < tmpl.type_params.len() {
        bound = ""
        if i < tmpl.type_param_bounds.len() {
            bound = tmpl.type_param_bounds.get(i)
        }
        if bound.len() > 0 and not sema_type_implements(s, encs.get(i), bound) {
            sema_error(s, line, col, "type `" + sema_env_display(encs.get(i)) +
                       "` does not implement interface `" + bound + "`")
            s.class_inst_errors.put(inst_name, 1)
            return ""
        }
        i = i + 1
    }
    child = Map[str, str]()
    i = 0
    while i < tmpl.type_params.len() {
        child.put(tmpl.type_params.get(i), encs.get(i))
        i = i + 1
    }
    old = s.type_env
    s.type_env = child

    inst = new_stmt(StmtClassDef(), tmpl.line, tmpl.col)
    inst.name = inst_name
    inst.module_name = tmpl.module_name
    inst.is_public = tmpl.is_public
    inst.interfaces = tmpl.interfaces
    i = 0
    while i < tmpl.fields.len() {
        fd = tmpl.fields.get(i)
        inst.fields.push(make_field(fd.name, sema_subst_te(s, fd.type)))
        i = i + 1
    }
    i = 0
    while i < tmpl.methods.len() {
        m = tmpl.methods.get(i)
        nm = new_stmt(StmtFnDef(), m.line, m.col)
        nm.name = m.name
        nm.module_name = m.module_name
        nm.is_public = m.is_public
        nm.body = m.body
        j = 0
        while j < m.params.len() {
            p = m.params.get(j)
            nm.params.push(make_param(p.name, sema_subst_te(s, p.type)))
            j = j + 1
        }
        nm.ret_type = sema_subst_te(s, m.ret_type)
        inst.methods.push(nm)
        i = i + 1
    }
    s.extra_stmts.push(inst)
    last_idx = s.extra_stmts.len() - 1
    sema_register_class(s, s.extra_stmts.get(last_idx))
    s.inst_envs.put(inst_name, sema_env_string(tmpl.type_params, encs))
    s.type_env = old
    return inst_name
}

public def sema_instantiate_enum(s: @var Sema, name: str, encs: List[str],
                          line: int, col: int) -> str {
    if not s.generic_enums.contains(name) {
        sema_error(s, line, col, "`" + sema_type_display(s, name) + "` is not a generic enum")
        return ""
    }
    tmpl = s.generic_enums.get(name)
    if encs.len() != tmpl.type_params.len() {
        key = name + "#count#" + to_string(encs.len())
        if not s.enum_inst_errors.contains(key) {
            s.enum_inst_errors.put(key, 1)
            sema_error(s, line, col, "enum `" + sema_type_display(s, name) + "` expects " +
                       to_string(tmpl.type_params.len()) + " type arguments, got " +
                       to_string(encs.len()))
        }
        return ""
    }
    inst_name = name
    i = 0
    while i < encs.len() {
        inst_name = inst_name + "$" + sema_env_display(encs.get(i))
        i = i + 1
    }
    if s.enum_variants.contains(inst_name) {
        return inst_name
    }
    child = Map[str, str]()
    i = 0
    while i < tmpl.type_params.len() {
        child.put(tmpl.type_params.get(i), encs.get(i))
        i = i + 1
    }
    old = s.type_env
    s.type_env = child

    inst = new_stmt(StmtEnumDef(), tmpl.line, tmpl.col)
    inst.name = inst_name
    inst.module_name = tmpl.module_name
    inst.is_public = tmpl.is_public
    i = 0
    while i < tmpl.variants.len() {
        v = tmpl.variants.get(i)
        nv = make_enum_variant(v.name, v.named_fields, List[FieldDecl]())
        j = 0
        while j < v.fields.len() {
            f = v.fields.get(j)
            nv.fields.push(make_field(f.name, sema_subst_te(s, f.type)))
            j = j + 1
        }
        inst.variants.push(nv)
        i = i + 1
    }
    s.extra_stmts.push(inst)
    last_idx = s.extra_stmts.len() - 1
    sema_register_enum(s, s.extra_stmts.get(last_idx))
    s.inst_envs.put(inst_name, sema_env_string(tmpl.type_params, encs))
    s.type_env = old
    return inst_name
}

public def sema_generic_fn_call(s: @var Sema, e: @Expr, gen_key: str) -> str {
    gen = s.generic_fns.get(gen_key)
    subst = Map[str, str]()
    i = 0
    while i < gen.params.len() and i < e.args.len() {
        pt = gen.params.get(i).type
        if pt.args.len() == 0 and gen.type_params.contains(pt.name) {
            ak = sema_check_expr(s, e.args.get(i))
            ac = sema_expr_custom(s, e.args.get(i))
            enc = sema_encode_kind(ak, ac)
            if subst.contains(pt.name) {
                if not str_eq(subst.get(pt.name), enc) {
                    sema_error(s, e.line, e.col, "type parameter `" + pt.name +
                               "` inferred inconsistently")
                    return "error"
                }
            } else {
                subst.put(pt.name, enc)
            }
        }
        i = i + 1
    }
    i = 0
    while i < gen.type_params.len() {
        if not subst.contains(gen.type_params.get(i)) {
            sema_error(s, e.line, e.col, "cannot infer type parameter `" +
                       gen.type_params.get(i) + "` for generic function `" + e.name + "`")
            return "error"
        }
        i = i + 1
    }
    i = 0
    while i < gen.type_params.len() {
        bound = ""
        if i < gen.type_param_bounds.len() {
            bound = gen.type_param_bounds.get(i)
        }
        if bound.len() > 0 and
           not sema_type_implements(s, subst.get(gen.type_params.get(i)), bound) {
            sema_error(s, e.line, e.col, "type `" +
                       sema_env_display(subst.get(gen.type_params.get(i))) +
                       "` does not implement interface `" + bound + "`")
            return "error"
        }
        i = i + 1
    }
    # Instance names are based on the template's physical key (module generic -> module$name$T), so definition/call symbols match.
    inst_name = gen_key
    encs = List[str]()
    i = 0
    while i < gen.type_params.len() {
        enc = subst.get(gen.type_params.get(i))
        encs.push(enc)
        inst_name = inst_name + "$" + sema_env_display(enc)
        i = i + 1
    }
    if not s.fn_ret_kinds.contains(inst_name) {
        child = Map[str, str]()
        i = 0
        while i < gen.type_params.len() {
            child.put(gen.type_params.get(i), encs.get(i))
            i = i + 1
        }
        old = s.type_env
        s.type_env = child
        inst = new_stmt(StmtFnDef(), gen.line, gen.col)
        inst.name = inst_name
        inst.module_name = gen.module_name
        inst.is_public = gen.is_public
        inst.is_async = gen.is_async
        inst.is_extern = gen.is_extern
        inst.body = gen.body
        i = 0
        while i < gen.params.len() {
            p = gen.params.get(i)
            inst.params.push(make_param(p.name, sema_subst_te(s, p.type)))
            i = i + 1
        }
        inst.ret_type = sema_subst_te(s, gen.ret_type)
        s.extra_stmts.push(inst)
        last_idx = s.extra_stmts.len() - 1
        sema_register_fn(s, inst_name, s.extra_stmts.get(last_idx), "")
        s.inst_envs.put(inst_name, sema_env_string(gen.type_params, encs))
        s.type_env = old
    }
    s.last_generic_custom = s.fn_ret_customs.get(inst_name)
    # Record call site -> instance physical name; the IR side uses it directly (no re-deriving instance names from bare names).
    s.call_syms.put(sema_call_key(s, @e), inst_name)
    sema_check_call_args(s, e, "function", e.name,
                         s.fn_param_kinds.get(inst_name),
                         s.fn_param_customs.get(inst_name), 0)
    if s.async_fns.contains(inst_name) {
        sema_async_task_of_fn(s, inst_name, e.line, e.col)
        s.last_generic_custom = sema_task_type(s.fn_ret_kinds.get(inst_name),
                                               s.fn_ret_customs.get(inst_name))
        return "custom"
    }
    return s.fn_ret_kinds.get(inst_name)
}

public def sema_register_class(s: @var Sema, c: Stmt) {
    name = c.name
    if s.class_fields.contains(name) {
        sema_error(s, c.line, c.col, "type `" + sema_type_display(s, name) + "` redefined")
        return
    }
    s.class_order.push(name)
    fnames = ""
    ftypes = ""
    fkinds = ""
    i = 0
    while i < c.fields.len() {
        fd = c.fields.get(i)
        if i > 0 {
            fnames = fnames + ","
            ftypes = ftypes + ","
            fkinds = fkinds + ","
        }
        fnames = fnames + fd.name
        fenc = sema_encode_type(s, fd.type)
        kind = sema_env_kind(fenc)
        fkinds = fkinds + kind
        if str_eq(kind, "custom") {
            ftypes = ftypes + llvm_type_of(kind, sema_env_display(fenc))
        } else {
            ftypes = ftypes + llvm_type_of_kind(kind)
        }
        i = i + 1
    }
    s.class_fields.put(name, fnames)
    s.class_field_types.put(name, ftypes)
    s.class_field_kinds.put(name, fkinds)
    ifaces = ""
    i = 0
    while i < c.interfaces.len() {
        if i > 0 {
            ifaces = ifaces + ","
        }
        ifaces = ifaces + sema_resolve_type_key(s, c.interfaces.get(i), c.line, c.col)
        i = i + 1
    }
    s.class_interfaces.put(name, ifaces)

    mnames = ""
    j = 0
    while j < c.methods.len() {
        m = c.methods.get(j)
        fn = name + "$" + m.name
        if j > 0 {
            mnames = mnames + ","
        }
        mnames = mnames + m.name
        sema_register_fn(s, fn, m, name)
        j = j + 1
    }
    s.class_methods.put(name, mnames)
    s.class_modules.put(name, c.module_name)
    if c.is_public {
        s.class_publics.put(name, 1)
    } else {
        s.class_publics.put(name, 0)
    }
    sema_check_interfaces(s, c)
}

# Register function signatures.
public def sema_register_fn(s: @var Sema, fn_name: str, f: Stmt, class_name: str) {
    s.fn_order.push(fn_name)
    renc = sema_encode_type(s, f.ret_type)
    ret_kind = sema_env_kind(renc)
    ret_custom = sema_env_custom(renc)
    s.fn_ret_kinds.put(fn_name, ret_kind)
    s.fn_ret_customs.put(fn_name, ret_custom)
    if str_eq(ret_kind, "None") {
        s.fn_ret_llvm.put(fn_name, "void")
    } else {
        s.fn_ret_llvm.put(fn_name, llvm_type_of(ret_kind, ret_custom))
    }

    if f.is_async {
        # async def: the body runs synchronously; the call site spawns a thread and returns Task[T].
        is_async = True
        if f.is_extern {
            sema_error(s, f.line, f.col, "extern function '" + fn_name + "' cannot be async")
            is_async = False
        }
        if not str_eq(class_name, "") {
            sema_error(s, f.line, f.col, "async methods are not supported")
            is_async = False
        }
        if str_eq(fn_name, "main") {
            sema_error(s, f.line, f.col,
                       "`main` cannot be async; use `asyncio.run(task)`")
            is_async = False
        }
        if f.ret_type.is_borrow {
            sema_error(s, f.line, f.col, "async function '" + fn_name +
                       "' cannot return a borrow")
            is_async = False
        }
        j = 0
        while j < f.params.len() {
            if f.params.get(j).type.is_borrow {
                sema_error(s, f.params.get(j).type.line, f.params.get(j).type.col,
                           "async function '" + fn_name + "' cannot take borrow parameter `" +
                           f.params.get(j).name + "`")
                is_async = False
            }
            j = j + 1
        }
        if is_async {
            s.async_fns.put(fn_name, 1)
        }
    }

    if f.is_extern {
        # extern def: a C-ABI declaration.
        # Params: int=i64 long long, float=double, bool=i8 _Bool, str=ptr;
        # Returns: int maps to i32 (C int; call sites sext back to i64), bool maps to i8.
        s.fn_is_extern.put(fn_name, 1)
        if f.type_params.len() > 0 {
            sema_error(s, f.line, f.col, "extern function '" + fn_name +
                       "' cannot be generic")
        }
        if not str_eq(ret_kind, "int") and not str_eq(ret_kind, "float") and
           not str_eq(ret_kind, "bool") and not str_eq(ret_kind, "str") and
           not str_eq(ret_kind, "None") {
            sema_error(s, f.line, f.col, "extern function '" + fn_name +
                       "' return type must be int/float/bool/str/None")
        }
        if str_eq(ret_kind, "int") {
            s.fn_ret_llvm.put(fn_name, "i32")
        } elif str_eq(ret_kind, "bool") {
            # C functions use "non-zero" boolean truth (glibc isdigit etc. return arbitrary non-zero values),
            # so declare as i32 and convert back to i1 at call sites with icmp ne 0.
            s.fn_ret_llvm.put(fn_name, "i32")
        }
        ptypes = ""
        pkinds = ""
        pcustoms = ""
        i = 0
        while i < f.params.len() {
            p = f.params.get(i)
            if i > 0 {
                ptypes = ptypes + ","
                pkinds = pkinds + ","
                pcustoms = pcustoms + ","
            }
            penc = sema_encode_type(s, p.type)
            kind = sema_env_kind(penc)
            if str_eq(p.type.name, "") or p.type.is_borrow or str_eq(kind, "custom") {
                sema_error(s, p.type.line, p.type.col, "extern function '" +
                           fn_name + "' parameter '" + p.name +
                           "' must be int/float/bool/str")
                kind = "int"
            }
            pkinds = pkinds + kind
            pcustoms = pcustoms + ""
            if str_eq(kind, "bool") {
                ptypes = ptypes + "i8"
            } else {
                ptypes = ptypes + llvm_type_of_kind(kind)
            }
            i = i + 1
        }
        s.fn_params_llvm.put(fn_name, ptypes)
        s.fn_param_kinds.put(fn_name, pkinds)
        s.fn_param_customs.put(fn_name, pcustoms)
        return
    }
    s.fn_is_extern.put(fn_name, 0)

    ptypes = ""
    pkinds = ""
    pcustoms = ""
    i = 0
    while i < f.params.len() {
        p = f.params.get(i)
        if i > 0 {
            ptypes = ptypes + ","
            pkinds = pkinds + ","
            pcustoms = pcustoms + ","
        }
        if not str_eq(class_name, "") and str_eq(p.name, "self") {
            ptypes = ptypes + "ptr"
            pkinds = pkinds + "custom"
            pcustoms = pcustoms + class_name
        } elif p.type.is_borrow {
            # Borrow parameters: @T / @var T — LLVM type is ptr; the custom name is marked with "@".
            penc = sema_encode_type(s, p.type)
            ptypes = ptypes + "ptr"
            pkinds = pkinds + "custom"
            pcustoms = pcustoms + "@" + sema_env_display(penc)
        } else {
            penc = sema_encode_type(s, p.type)
            kind = sema_env_kind(penc)
            pkinds = pkinds + kind
            if str_eq(kind, "custom") {
                ptypes = ptypes + llvm_type_of(kind, sema_env_display(penc))
                pcustoms = pcustoms + sema_env_display(penc)
            } else {
                ptypes = ptypes + llvm_type_of_kind(kind)
                pcustoms = pcustoms + ""
            }
        }
        i = i + 1
    }
    s.fn_params_llvm.put(fn_name, ptypes)
    s.fn_param_kinds.put(fn_name, pkinds)
    s.fn_param_customs.put(fn_name, pcustoms)
}

# Register enum definitions.
public def sema_register_enum(s: @var Sema, e: Stmt) {
    name = e.name
    if s.enum_field_kinds.contains(name) {
        sema_error(s, e.line, e.col, "type `" + sema_type_display(s, name) + "` redefined")
        return
    }
    s.enum_order.push(name)
    vnames = ""
    kinds_all = ""
    names_all = ""
    max_fields = 0
    i = 0
    while i < e.variants.len() {
        v = e.variants.get(i)
        if i > 0 {
            vnames = vnames + ","
        }
        vnames = vnames + v.name
        s.enum_variant_enum.put(v.name, name)
        s.enum_variant_idx.put(v.name, i)

        if v.fields.len() > max_fields {
            max_fields = v.fields.len()
        }
        kinds = ""
        fnames = ""
        j = 0
        while j < v.fields.len() {
            fd = v.fields.get(j)
            if j > 0 {
                kinds = kinds + ","
                fnames = fnames + ","
            }
            kinds = kinds + sema_te_kind(s, fd.type)
            fnames = fnames + fd.name
            j = j + 1
        }
        if i > 0 {
            kinds_all = kinds_all + "|"
            names_all = names_all + "|"
        }
        kinds_all = kinds_all + kinds
        names_all = names_all + fnames
        i = i + 1
    }
    s.enum_variants.put(name, vnames)
    s.enum_payloads.put(name, max_fields)
    s.enum_field_kinds.put(name, kinds_all)
    s.enum_field_names.put(name, names_all)
}

# ---------------------------------------------------------------------------
# Program checking
# ---------------------------------------------------------------------------

public def sema_match_variant_idx(s: @var Sema, enum_name: str, variant: str) -> int {
    if enum_name.startswith("Maybe$") {
        if str_eq(variant, "Some") { return 0 }
        if str_eq(variant, "Nothing") { return 1 }
    }
    if enum_name.startswith("Result$") {
        if str_eq(variant, "Ok") { return 0 }
        if str_eq(variant, "Err") { return 1 }
    }
    if s.enum_variant_enum.contains(variant) and
       str_eq(s.enum_variant_enum.get(variant), enum_name) {
        return s.enum_variant_idx.get(variant)
    }
    return -1
}

public def sema_declare_var(s: @var Sema, name: str, kind: str, custom: str) {
    if not s.cur_var_seen.contains(name) {
        s.cur_var_seen.put(name, 1)
        s.cur_var_names.push(name)
    }
    s.cur_locals.put(name, kind)
    s.cur_local_customs.put(name, custom)
    s.cur_moved.put(name, 0)
    s.cur_borrow_shared.put(name, 0)
    s.cur_borrow_mut.put(name, 0)
    s.cur_borrow_target.put(name, "")
    s.cur_handle_mut.put(name, 0)
}

# Recursively detect explicit returns to decide whether the trailing expression is the return value.
public def sema_expr_has_return(e: Expr) -> bool {
    if e.kind == ExprBlock() {
        i = 0
        while i < e.stmts.len() {
            if sema_stmt_has_return(e.stmts.get(i)) {
                return True
            }
            i = i + 1
        }
        if e.result.len() > 0 {
            return sema_expr_has_return(e.result.get(0))
        }
        return False
    }
    if e.kind == ExprIf() {
        if e.then_block.len() > 0 and sema_expr_has_return(e.then_block.get(0)) {
            return True
        }
        if e.else_block.len() > 0 and sema_expr_has_return(e.else_block.get(0)) {
            return True
        }
        return False
    }
    if e.kind == ExprMatch() {
        i = 0
        while i < e.arms.len() {
            if sema_expr_has_return(e.arms.get(i).body) {
                return True
            }
            i = i + 1
        }
    }
    return False
}

public def sema_stmt_has_return(st: Stmt) -> bool {
    if st.kind == StmtReturn() {
        return True
    }
    if st.kind == StmtExpr() {
        return sema_expr_has_return(st.expr)
    }
    if st.kind == StmtFor() or st.kind == StmtWhile() {
        i = 0
        while i < st.body.len() {
            if sema_stmt_has_return(st.body.get(i)) {
                return True
            }
            i = i + 1
        }
    }
    return False
}

public def sema_bind_pattern(s: @var Sema, p: Pattern, enum_name: str, v_idx: int,
                      subject_kind: str, subject_custom: str, line: int, col: int) {
    if p.kind == PatternWildcard() {
        return
    }
    if p.kind == PatternVar() {
        sema_declare_var(s, p.name, subject_kind, subject_custom)
        return
    }
    if p.kind == PatternVariant() {
        if v_idx < 0 {
            return
        }
        if not s.enum_field_kinds.contains(enum_name) {
            return
        }
        kinds_all = s.enum_field_kinds.get(enum_name).split("|")
        fkinds = List[str]()
        if v_idx < kinds_all.len() {
            fkinds = kinds_all.get(v_idx).split(",")
        }
        i = 0
        while i < p.fields.len() {
            k = "int"
            if i < fkinds.len() {
                k = fkinds.get(i)
            }
            sub = p.fields.get(i)
            if sub.kind == PatternVar() {
                sema_declare_var(s, sub.name, k, "")
            }
            i = i + 1
        }
    }
}

public def sema_check_program(s: @var Sema, stmts: @List[Stmt]) {
    sema_register_builtins(s)

    # Pass -1: namespace materialization.
    #   - class/enum/interface registration names are rewritten to module$Name (the entry file keeps bare names, physically isolating same-named types)
    #   - collect type names declared by each module (module_types, for forward references and cross-module resolution)
    #   - collect from-import scopes (from_imports)
    #   - record type owners (same-named types across modules are registered separately; ambiguities error at use sites)
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtImport() {
            mod_canon = module_canon(st.import_module)
            if st.import_glob {
                # from m import *: record the glob scope (look for a unique candidate in the export table during resolution).
                gkey = st.module_name + "$" + mod_canon
                if not s.glob_imports.contains(gkey) {
                    s.glob_imports.push(gkey)
                }
            } elif st.import_names.len() > 0 {
                j = 0
                while j < st.import_names.len() {
                    alias = st.import_aliases.get(j)
                    if alias.len() == 0 {
                        alias = st.import_names.get(j)
                    }
                    s.from_imports.put(st.module_name + "$" + alias,
                                       mod_canon + "." + st.import_names.get(j))
                    j = j + 1
                }
            } else {
                # Plain import: bound name (as alias or last path segment) -> canonical module name.
                bound = st.import_alias
                if bound.len() == 0 {
                    slash = str_rfind(st.import_module, "/")
                    if slash >= 0 {
                        bound = st.import_module.slice(slash + 1, st.import_module.len())
                    } else {
                        bound = st.import_module
                    }
                }
                bkey = st.module_name + "$" + bound
                if s.module_bindings.contains(bkey) and
                   not str_eq(s.module_bindings.get(bkey), mod_canon) {
                    sema_error(s, st.line, st.col, "module binding `" + bound +
                               "` conflicts with `" + s.module_bindings.get(bkey) + "`")
                } else {
                    s.module_bindings.put(bkey, mod_canon)
                }
            }
        } elif st.kind == StmtClassDef() or st.kind == StmtEnumDef() or
               st.kind == StmtInterfaceDef() {
            if st.module_name.len() > 0 {
                orig = st.name
                s.module_types.put(st.module_name + "$" + orig, "")
                sema_record_type_owner(s, st.module_name, orig)
                st.name = st.module_name + "$" + st.name
                s.type_orig.put(st.name, orig)
                # Stmt is taken by value; write the renamed copy back to the merged list (registration and IR both use physical names).
                stmts.set(i, st)
            } else {
                s.module_types.put("$" + st.name, "")
            }
        }
        i = i + 1
    }

    # Pass 0: register interfaces first, then collect generic templates.
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtInterfaceDef() {
            sema_register_interface(s, stmts.get(i))
        }
        i = i + 1
    }
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        old_module0 = s.current_module
        s.current_module = st.module_name
        if st.module_name.len() > 0 {
            s.module_names.put(st.module_name, 1)
        }
        if st.kind == StmtFnDef() and st.is_extern and st.type_params.len() > 0 {
            sema_error(s, st.line, st.col,
                       "extern function '" + st.name + "' cannot be generic")
        }
        if st.type_params.len() > 0 {
            # Generic bounds ([T: Show]) are resolved to interface registration keys during template collection.
            bi = 0
            while bi < st.type_param_bounds.len() {
                b = st.type_param_bounds.get(bi)
                if b.len() > 0 {
                    st.type_param_bounds.set(bi, sema_resolve_type_key(s, b, st.line, st.col))
                }
                bi = bi + 1
            }
            if st.kind == StmtFnDef() {
                gm = st.module_name
                gn = st.name
                gp = st.is_public
                # Module generic functions are physically renamed under the same rules as plain functions, so instance names carry the prefix.
                if gm.len() > 0 {
                    st.name = gm + "$" + st.name
                }
                s.generic_fn_names.push(st.name)
                s.generic_fns.put(st.name, st)
                # Export records use the original source bare name (resolution chains look up bare name -> owner).
                if gm.len() > 0 {
                    if gp {
                        sema_record_export(s, gm, gn)
                    } else {
                        s.private_fns.put(gn, gm)
                    }
                }
            } elif st.kind == StmtClassDef() {
                s.generic_classes.put(st.name, st)
            } elif st.kind == StmtEnumDef() {
                s.generic_enums.put(st.name, st)
            }
        }
        s.current_module = old_module0
        i = i + 1
    }

    # Pass 1: register concrete top-level functions / classes / enums (may trigger generic instantiation).
    # Encoding fields/return types during registration needs module context (type-name resolution depends on current_module).
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        old_module1 = s.current_module
        s.current_module = st.module_name
        if st.type_params.len() == 0 {
            if st.kind == StmtFnDef() {
                internal = st.name
                if st.module_name.len() > 0 and not st.is_extern {
                    internal = st.module_name + "$" + st.name
                }
                if st.module_name.len() > 0 {
                    s.module_names.put(st.module_name, 1)
                    if st.is_public {
                        s.module_exports.put(st.module_name + "." + st.name, internal)
                        sema_record_export(s, st.module_name, st.name)
                    } else {
                        s.private_fns.put(st.name, st.module_name)
                    }
                }
                sema_register_fn(s, internal, st, "")
            } elif st.kind == StmtClassDef() {
                sema_register_class(s, st)
            } elif st.kind == StmtEnumDef() {
                sema_register_enum(s, st)
            }
        }
        s.current_module = old_module1
        i = i + 1
    }

    # Pass 1.5: public from-import re-exports (like Rust's `pub use`).
    # After Pass 1 completes the module export table, hang source-module symbols on the current module's export table;
    # chained re-exports (a re-exports b's symbol, c re-exports a's) are resolved by fixed-point iteration.
    # Re-exports from the entry file (empty module_name) are treated as plain imports: the entry cannot be imported by other modules.
    repasses = 0
    rechanged = True
    while rechanged and repasses < 10 {
        rechanged = False
        repasses = repasses + 1
        i = 0
        while i < stmts.len() {
            st = stmts.get(i)
            if st.kind == StmtImport() and st.is_public and st.import_names.len() > 0 and
               st.module_name.len() > 0 {
                j = 0
                while j < st.import_names.len() {
                    name = st.import_names.get(j)
                    alias = st.import_aliases.get(j)
                    if alias.len() == 0 {
                        alias = name
                    }
                    src_canon = module_canon(st.import_module)
                    dk = st.module_name + "." + alias
                    ek = src_canon + "." + name
                    if s.module_exports.contains(ek) {
                        if not s.module_exports.contains(dk) {
                            s.module_exports.put(dk, s.module_exports.get(ek))
                            sema_record_export(s, st.module_name, alias)
                            rechanged = True
                        }
                    } elif s.generic_fns.contains(src_canon + "$" + name) {
                        priv = s.private_fns.contains(name) and
                               str_eq(s.private_fns.get(name), src_canon)
                        if not priv and not s.module_exports.contains(dk) {
                            s.module_exports.put(dk, src_canon + "$" + name)
                            sema_record_export(s, st.module_name, alias)
                            rechanged = True
                        }
                    } elif s.module_types.contains(src_canon + "$" + name) {
                        tkey = src_canon + "$" + name
                        # Private types cannot be re-exported (like Rust E0365).
                        if s.class_modules.contains(tkey) and s.class_publics.contains(tkey) {
                            if s.class_publics.get(tkey) == 0 {
                                sema_error(s, st.line, st.col,
                                           "cannot re-export private type `" + name +
                                           "` of module `" + src_canon + "`")
                            }
                        }
                        rk = st.module_name + "$" + alias
                        if not s.type_reexports.contains(rk) {
                            s.type_reexports.put(rk, tkey)
                            rechanged = True
                        }
                    }
                    j = j + 1
                }
            }
            i = i + 1
        }
    }

    # Re-export validation: a public from-import that still has no target after the fixed point is an error.
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.kind == StmtImport() and st.is_public and st.import_names.len() > 0 and
           st.module_name.len() > 0 {
            j = 0
            while j < st.import_names.len() {
                name = st.import_names.get(j)
                alias = st.import_aliases.get(j)
                if alias.len() == 0 {
                    alias = name
                }
                if not s.module_exports.contains(st.module_name + "." + alias) and
                   not s.type_reexports.contains(st.module_name + "$" + alias) {
                    sema_error(s, st.line, st.col, "cannot re-export `" + name +
                               "`: no public symbol `" + name + "` in module `" +
                               module_canon(st.import_module) + "`")
                }
                j = j + 1
            }
        }
        i = i + 1
    }

    # Pass 2: check non-generic function bodies.
    j = 0
    while j < stmts.len() {
        st = stmts.get(j)
        if st.type_params.len() == 0 {
            old_module = s.current_module
            s.current_module = st.module_name
            if st.kind == StmtFnDef() {
                sema_check_fn(s, st, "")
            } elif st.kind == StmtClassDef() {
                k = 0
                while k < st.methods.len() {
                    m = st.methods.get(k)
                    sema_check_fn(s, m, st.name)
                    k = k + 1
                }
            }
            s.current_module = old_module
        }
        j = j + 1
    }

    # Pass 3: check lazily generated generic instances (more instances may be appended during this pass).
    idx = 0
    while idx < s.extra_stmts.len() {
        st = s.extra_stmts.get(idx)
        envstr = ""
        if st.kind == StmtFnDef() and s.inst_envs.contains(st.name) {
            envstr = s.inst_envs.get(st.name)
        } elif st.kind == StmtClassDef() and s.inst_envs.contains(st.name) {
            envstr = s.inst_envs.get(st.name)
        }
        old = s.type_env
        old_module = s.current_module
        s.current_module = st.module_name
        if envstr.len() > 0 {
            sema_apply_env_string(s, envstr)
        }
        if st.kind == StmtFnDef() {
            sema_check_fn(s, st, "")
        } elif st.kind == StmtClassDef() {
            k = 0
            while k < st.methods.len() {
                m = st.methods.get(k)
                sema_check_fn(s, m, st.name)
                k = k + 1
            }
        }
        s.type_env = old
        s.current_module = old_module
        idx = idx + 1
    }
}

public def sema_check_fn(s: @var Sema, f: Stmt, class_name: str) {
    # extern declarations have no body: their registry entry already exists, so skip checking.
    if f.is_extern {
        return
    }
    # Function-level scope.
    s.cur_locals = Map[str, str]()
    s.cur_local_customs = Map[str, str]()
    sema_reset_var_state(s)
    s.check_depth = 0
    s.in_expr_stmt = 0
    s.cur_fn_name = f.name
    if f.is_async {
        s.cur_fn_async = 1
    } else {
        s.cur_fn_async = 0
    }
    renc = sema_encode_type(s, f.ret_type)
    s.cur_fn_ret_kind = sema_env_kind(renc)
    s.cur_fn_ret_custom = sema_env_custom(renc)

    i = 0
    while i < f.params.len() {
        p = f.params.get(i)
        if not str_eq(class_name, "") and str_eq(p.name, "self") {
            sema_declare_var(s, p.name, "custom", class_name)
        } else {
            penc = sema_encode_type(s, p.type)
            kind = sema_env_kind(penc)
            custom = sema_env_custom(penc)
            sema_declare_var(s, p.name, kind, custom)
        }
        i = i + 1
    }

    has_ret = False
    i = 0
    while i < f.body.len() {
        if sema_stmt_has_return(f.body.get(i)) {
            has_ret = True
        }
        i = i + 1
    }

    last_idx = f.body.len() - 1
    k = 0
    while k < f.body.len() {
        st = f.body.get(k)
        if k == last_idx and not has_ret and
           not str_eq(s.cur_fn_ret_kind, "None") and st.kind == StmtExpr() {
            lk = sema_check_expr(s, st.expr)
            lc = sema_expr_custom(s, st.expr)
            if not sema_can_assign(lk, lc, s.cur_fn_ret_kind, s.cur_fn_ret_custom) {
                sema_error(s, st.expr.line, st.expr.col,
                           "function '" + f.name + "' returns `" + sema_type_name(lk, lc) +
                           "`, expected `" +
                           sema_type_name(s.cur_fn_ret_kind, s.cur_fn_ret_custom) + "`")
            }
        } else {
            sema_check_stmt(s, st)
        }
        k = k + 1
    }
}

public def sema_check_stmt(s: @var Sema, st: Stmt) {
    if st.kind == StmtExpr() {
        # if/blocks in statement position: the branch trailing-expression types need not agree (values are discarded).
        old_es = s.in_expr_stmt
        s.in_expr_stmt = 1
        sema_check_expr(s, st.expr)
        s.in_expr_stmt = old_es
        pass
    } elif st.kind == StmtReturn() {
        if st.value.kind != ExprNoneLit() {
            vk = sema_check_expr(s, st.value)
            vc = sema_expr_custom(s, st.value)
            if not str_eq(s.cur_fn_ret_kind, "None") and
               not sema_can_assign(vk, vc, s.cur_fn_ret_kind, s.cur_fn_ret_custom) {
                sema_error(s, st.value.line, st.value.col,
                           "function '" + s.cur_fn_name + "' returns `" +
                           sema_type_name(vk, vc) + "`, expected `" +
                           sema_type_name(s.cur_fn_ret_kind, s.cur_fn_ret_custom) + "`")
            }
        }
        pass
    } elif st.kind == StmtFor() {
        is_range = st.iterable.kind == ExprCall() and str_eq(st.iterable.name, "range")
        elem_kind = "int"
        elem_custom = ""
        if is_range {
            if st.iterable.args.len() < 1 or st.iterable.args.len() > 3 {
                sema_error(s, st.iterable.line, st.iterable.col,
                           "range() expects 1 to 3 arguments")
            } else {
                ai = 0
                while ai < st.iterable.args.len() {
                    rk = sema_check_expr(s, st.iterable.args.get(ai))
                    if not str_eq(rk, "int") {
                        sema_error(s, st.iterable.args.get(ai).line,
                                   st.iterable.args.get(ai).col,
                                   "range() expects int, found `" + rk + "`")
                    }
                    ai = ai + 1
                }
            }
        } else {
            sema_check_expr(s, st.iterable)
            ic = sema_expr_custom(s, st.iterable)
            if ic.startswith("List$") {
                elem = ic.slice(5, ic.len())
                elem_kind = elem_kind_of_mangled(elem)
                if str_eq(elem_kind, "custom") {
                    elem_custom = elem
                }
            }
        }
        sema_declare_var(s, st.var_name, elem_kind, elem_custom)
        s.loop_depth = s.loop_depth + 1
        k = 0
        while k < st.body.len() {
            sema_check_stmt(s, st.body.get(k))
            k = k + 1
        }
        s.loop_depth = s.loop_depth - 1
        pass
    } elif st.kind == StmtWhile() {
        sema_check_expr(s, st.value)
        s.loop_depth = s.loop_depth + 1
        k = 0
        while k < st.body.len() {
            sema_check_stmt(s, st.body.get(k))
            k = k + 1
        }
        s.loop_depth = s.loop_depth - 1
        pass
    } elif st.kind == StmtBreak() {
        if s.loop_depth == 0 {
            sema_error(s, st.line, st.col, "`break` outside of a loop")
        }
        pass
    } elif st.kind == StmtContinue() {
        if s.loop_depth == 0 {
            sema_error(s, st.line, st.col, "`continue` outside of a loop")
        }
        pass
    } elif st.kind == StmtFnDef() or st.kind == StmtClassDef() or
         st.kind == StmtEnumDef() or st.kind == StmtInterfaceDef() or st.kind == StmtImport() {
        # Nested definitions / imports are handled at the program level.
        pass
    }
}

public def sema_save_state(s: @var Sema) -> SemaState {
    st = SemaState()
    st.names = List[str]()
    st.moved = List[int]()
    st.shared = List[int]()
    st.muts = List[int]()
    st.handle_mut = List[int]()
    st.targets = List[str]()
    i = 0
    while i < s.cur_var_names.len() {
        name = s.cur_var_names.get(i)
        st.names.push(name)
        st.moved.push(s.cur_moved.get(name))
        st.shared.push(sema_shared_count(s, name))
        st.muts.push(sema_mut_count(s, name))
        st.handle_mut.push(s.cur_handle_mut.get(name))
        st.targets.push(s.cur_borrow_target.get(name))
        i = i + 1
    }
    return st
}

public def sema_restore_state(s: @var Sema, st: SemaState) {
    i = 0
    while i < st.names.len() {
        name = st.names.get(i)
        s.cur_moved.put(name, st.moved.get(i))
        s.cur_borrow_shared.put(name, st.shared.get(i))
        s.cur_borrow_mut.put(name, st.muts.get(i))
        s.cur_handle_mut.put(name, st.handle_mut.get(i))
        s.cur_borrow_target.put(name, st.targets.get(i))
        i = i + 1
    }
}

# Conservative join: if any branch moved the variable, it is moved; borrow counts take the larger value.
public def sema_merge_state(s: @var Sema, st: SemaState) {
    i = 0
    while i < st.names.len() {
        name = st.names.get(i)
        if st.moved.get(i) == 1 {
            s.cur_moved.put(name, 1)
        }
        if st.shared.get(i) > sema_shared_count(s, name) {
            s.cur_borrow_shared.put(name, st.shared.get(i))
        }
        if st.muts.get(i) > sema_mut_count(s, name) {
            s.cur_borrow_mut.put(name, st.muts.get(i))
        }
        if st.targets.get(i).len() > 0 {
            s.cur_borrow_target.put(name, st.targets.get(i))
            s.cur_handle_mut.put(name, st.handle_mut.get(i))
        }
        i = i + 1
    }
}

public def sema_release_borrow(s: @var Sema, name: str, is_mut: bool) {
    if is_mut {
        c = sema_mut_count(s, name)
        if c > 0 {
            s.cur_borrow_mut.put(name, c - 1)
        }
    } else {
        c = sema_shared_count(s, name)
        if c > 0 {
            s.cur_borrow_shared.put(name, c - 1)
        }
    }
}

# Check borrow expressions and maintain borrow counts.
public def sema_check_borrow(s: @var Sema, e: @Expr) -> str {
    op = e.operand.get(0)
    if op.kind != ExprVar() {
        sema_error(s, e.line, e.col, "borrow target must be a variable")
        return "error"
    }
    name = op.name
    if not s.cur_locals.contains(name) {
        sema_error(s, op.line, op.col, "use of undeclared variable `" + name + "`")
        return "error"
    }
    if sema_is_moved(s, name) {
        sema_error(s, op.line, op.col, "use of moved value: `" + name + "`")
        return "error"
    }
    sc = sema_shared_count(s, name)
    mc = sema_mut_count(s, name)
    if e.is_mut {
        if sc > 0 {
            sema_error(s, e.line, e.col,
                       "cannot borrow `" + name + "` as @var because it is also borrowed as @")
        } elif mc > 0 {
            sema_error(s, e.line, e.col,
                       "cannot borrow `" + name + "` as @var because it is also borrowed as @var")
        } else {
            s.cur_borrow_mut.put(name, mc + 1)
        }
    } else {
        if mc > 0 {
            sema_error(s, e.line, e.col,
                       "cannot borrow `" + name + "` as @ because it is also borrowed as @var")
        } else {
            s.cur_borrow_shared.put(name, sc + 1)
        }
    }
    return s.cur_locals.get(name)
}

# Split a Result mangled name (same convention as IR/enum layouts; split at the first $).
public def sema_result_parts(custom: str) -> List[str] {
    parts = List[str]()
    if custom.startswith("Result$") {
        rest = custom.slice(7, custom.len())
        d = str_find(rest, "$")
        if d >= 0 {
            parts.push(rest.slice(0, d))
            parts.push(rest.slice(d + 1, rest.len()))
        }
    }
    return parts
}

# `expr?`: requires the operand to be a Result whose error type matches the enclosing function's return.
public def sema_check_try(s: @var Sema, e: @Expr) -> str {
    op = e.operand.get(0)
    k = sema_check_expr(s, op)
    oc = sema_expr_custom(s, e.operand.get(0))
    if str_eq(k, "error") {
        return "error"
    }
    parts = sema_result_parts(oc)
    if parts.len() != 2 {
        sema_error(s, e.line, e.col,
                   "`?` requires a Result value, found `" +
                   sema_type_name(k, oc) + "`")
        return "error"
    }
    ret_parts = sema_result_parts(s.cur_fn_ret_custom)
    if ret_parts.len() != 2 {
        sema_error(s, e.line, e.col,
                   "`?` can only be used in a function returning Result, found `" +
                   sema_type_name(s.cur_fn_ret_kind, s.cur_fn_ret_custom) + "`")
        return "error"
    }
    if not str_eq(parts.get(1), ret_parts.get(1)) {
        sema_error(s, e.line, e.col,
                   "`?` error type mismatch: operator produces `" + parts.get(1) +
                   "`, function returns `" + ret_parts.get(1) + "`")
        return "error"
    }
    ok_kind = elem_kind_of_mangled(parts.get(0))
    if str_eq(ok_kind, "custom") {
        sema_error(s, e.line, e.col,
                   "`?` does not support custom success payload `" + parts.get(0) +
                   "` yet")
        return "error"
    }
    return ok_kind
}

# Check argument counts/types; skip_self=1 skips the method self.
public def sema_check_call_args(s: @var Sema, e: @Expr, label: str, fname: str,
                         pkinds: str, pcustoms: str, skip_self: int) -> bool {
    klist = List[str]()
    clist = List[str]()
    if pkinds.len() > 0 {
        klist = pkinds.split(",")
    }
    if pcustoms.len() > 0 {
        clist = pcustoms.split(",")
    }
    expected = klist.len() - skip_self
    if expected < 0 {
        expected = 0
    }
    if e.args.len() != expected {
        sema_error(s, e.line, e.col, label + " `" + fname + "` expects " +
                   to_string(expected) + " arguments, got " + to_string(e.args.len()))
        return False
    }
    j = 0
    while j < e.args.len() {
        arg = e.args.get(j)
        pi = j + skip_self
        pk = klist.get(pi)
        pc = ""
        if pi < clist.len() {
            pc = clist.get(pi)
        }
        is_borrow_param = pc.startswith("@")
        if is_borrow_param {
            pc = pc.slice(1, pc.len())
        }
        ak = ""
        ac = ""
        if is_borrow_param and arg.kind == ExprBorrow() {
            ak = sema_check_borrow(s, @arg)
            ac = sema_expr_custom(s, e.args.get(j).operand.get(0))
            op0 = arg.operand.get(0)
            if op0.kind == ExprVar() {
                sema_release_borrow(s, op0.name, arg.is_mut)
            }
        } else {
            ak = sema_check_expr(s, e.args.get(j))
            ac = sema_expr_custom(s, e.args.get(j))
        }
        if not sema_can_assign(ak, ac, pk, pc) {
            sema_error(s, arg.line, arg.col, "argument " + to_string(j + 1) + " to `" +
                       fname + "` has type `" + sema_type_name(ak, ac) + "`, expected `" +
                       sema_type_name(pk, pc) + "`")
        }
        if not is_borrow_param and str_eq(pk, "custom") and
           arg.kind == ExprVar() {
            if s.cur_borrow_target.contains(arg.name) and
               s.cur_borrow_target.get(arg.name).len() > 0 {
                sema_error(s, arg.line, arg.col,
                           "cannot copy a borrow handle; create a new borrow with `@` or `@var`")
            } elif sema_shared_count(s, arg.name) > 0 or sema_mut_count(s, arg.name) > 0 {
                sema_error(s, arg.line, arg.col, "cannot move out of `" + arg.name +
                           "` because it is borrowed")
            } else {
                sema_mark_moved(s, arg.name)
            }
        }
        j = j + 1
    }
    return True
}

# await consumes the Task; re-awaiting / awaiting a borrowed Task is intercepted here.
public def sema_consume_task(s: @var Sema, op: Expr) {
    if op.kind == ExprVar() {
        if sema_is_moved(s, op.name) {
            return
        }
        if sema_shared_count(s, op.name) > 0 or sema_mut_count(s, op.name) > 0 {
            sema_error(s, op.line, op.col, "cannot await `" + op.name +
                       "` because it is borrowed")
        }
        sema_mark_moved(s, op.name)
    }
}

public def sema_check_await(s: @var Sema, e: @Expr) -> str {
    if s.cur_fn_async == 0 {
        sema_error(s, e.line, e.col, "`await` is only allowed inside an async function")
    }
    if e.operand.len() == 0 {
        return "error"
    }
    k = sema_check_expr(s, e.operand.get(0))
    c = sema_expr_custom(s, e.operand.get(0))
    task = ""
    if str_eq(k, "custom") {
        task = c
    }
    if not task.startswith("Task$") {
        sema_error(s, e.line, e.col, "`await` expects a Task value, found `" +
                   sema_type_name(k, c) + "`")
        return "error"
    }
    sema_consume_task(s, e.operand.get(0))
    return sema_payload_kind(sema_task_payload(task))
}

public def sema_check_asyncio_run(s: @var Sema, e: @Expr) -> str {
    if e.args.len() != 1 {
        sema_error(s, e.line, e.col, "asyncio.run() expects 1 argument")
        i = 0
        while i < e.args.len() {
            sema_check_expr(s, e.args.get(i))
            i = i + 1
        }
        return "error"
    }
    k = sema_check_expr(s, e.args.get(0))
    c = sema_expr_custom(s, e.args.get(0))
    task = ""
    if str_eq(k, "custom") {
        task = c
    }
    if not task.startswith("Task$") {
        sema_error(s, e.line, e.col, "asyncio.run() expects a Task value, found `" +
                   sema_type_name(k, c) + "`")
        return "error"
    }
    sema_consume_task(s, e.args.get(0))
    return sema_payload_kind(sema_task_payload(task))
}

# asyncio.cancelled(): whether the current task received a cancellation request; always false outside a task.
public def sema_check_asyncio_cancelled(s: @var Sema, e: @Expr) -> str {
    if e.args.len() != 0 {
        sema_error(s, e.line, e.col, "asyncio.cancelled() takes no arguments")
        i = 0
        while i < e.args.len() {
            sema_check_expr(s, e.args.get(i))
            i = i + 1
        }
    }
    return "bool"
}

# gather consumes the whole task list; this prevents using dangling Task handles after the join.
public def sema_consume_gather_list(s: @var Sema, op: Expr) {
    if op.kind == ExprVar() {
        if sema_is_moved(s, op.name) {
            return
        }
        if sema_shared_count(s, op.name) > 0 or sema_mut_count(s, op.name) > 0 {
            sema_error(s, op.line, op.col, "cannot gather `" + op.name +
                       "` because it is borrowed")
        }
        sema_mark_moved(s, op.name)
    }
}

# asyncio.gather(tasks):List[Task[T]] -> Task[List[T]].
public def sema_check_asyncio_gather(s: @var Sema, e: @Expr) -> str {
    if e.args.len() != 1 {
        sema_error(s, e.line, e.col, "asyncio.gather() expects 1 argument")
        i = 0
        while i < e.args.len() {
            sema_check_expr(s, e.args.get(i))
            i = i + 1
        }
        return "error"
    }
    k = sema_check_expr(s, e.args.get(0))
    c = sema_expr_custom(s, e.args.get(0))
    if not str_eq(k, "custom") or not c.startswith("List$Task$") {
        sema_error(s, e.line, e.col,
                   "asyncio.gather() expects List[Task[T]], found `" +
                   sema_type_name(k, c) + "`")
        return "error"
    }
    elem = c.slice(5, c.len())
    p = sema_task_payload(elem)
    if str_eq(p, "None") {
        sema_error(s, e.line, e.col,
                   "asyncio.gather() does not support tasks without a value yet")
        return "error"
    }
    sema_consume_gather_list(s, e.args.get(0))
    sema_async_task(s, "custom", "List$" + p, e.line, e.col)
    return "custom"
}

# asyncio.wait_any(tasks): returns the index of the first completed task; an empty list returns -1 without consuming.
public def sema_check_asyncio_wait_any(s: @var Sema, e: @Expr) -> str {
    if e.args.len() != 1 {
        sema_error(s, e.line, e.col, "asyncio.wait_any() expects 1 argument")
        i = 0
        while i < e.args.len() {
            sema_check_expr(s, e.args.get(i))
            i = i + 1
        }
        return "error"
    }
    k = sema_check_expr(s, e.args.get(0))
    c = sema_expr_custom(s, e.args.get(0))
    if not str_eq(k, "custom") or not c.startswith("List$Task$") {
        sema_error(s, e.line, e.col,
                   "asyncio.wait_any() expects List[Task[T]], found `" +
                   sema_type_name(k, c) + "`")
        return "error"
    }
    return "int"
}

# Expression checking: variables exist, functions/methods exist, argument counts, binary operator types.
public def sema_check_expr(s: @var Sema, e: Expr) -> str {
    s.check_depth = s.check_depth + 1
    if s.check_depth == 10001 {
        write_stderr("sema depth overflow at " + to_string(e.line) + ":" +
                     to_string(e.col) + "\n")
    }
    if s.check_depth > 100000 {
        return "error"
    }
    if e.kind == ExprIntLit() {
        return "int"
    }
    if e.kind == ExprNoneLit() {
        return "None"
    }
    if e.kind == ExprFloatLit() {
        return "float"
    }
    if e.kind == ExprBoolLit() {
        return "bool"
    }
    if e.kind == ExprStringLit() {
        return "str"
    }
    if e.kind == ExprVar() {
        if not s.cur_locals.contains(e.name) {
            sema_error(s, e.line, e.col, "use of undeclared variable `" + e.name + "`")
            return "error"
        }
        sema_check_use(s, e.name, e.line, e.col)
        return s.cur_locals.get(e.name)
    }
    if e.kind == ExprUnary() {
        k = sema_check_expr(s, e.operand.get(0))
        if str_eq(e.op, "not") {
            return "bool"
        }
        return k
    }
    if e.kind == ExprBorrow() {
        return sema_check_borrow(s, @e)
    }
    if e.kind == ExprTry() {
        return sema_check_try(s, @e)
    }
    if e.kind == ExprAwait() {
        return sema_check_await(s, @e)
    }
    if e.kind == ExprBinary() {
        lk = sema_check_expr(s, e.lhs.get(0))
        rk = sema_check_expr(s, e.rhs.get(0))
        if str_eq(e.op, "and") or str_eq(e.op, "or") or
           str_eq(e.op, "==") or str_eq(e.op, "!=") or
           str_eq(e.op, "<") or str_eq(e.op, "<=") or
           str_eq(e.op, ">") or str_eq(e.op, ">=") {
            return "bool"
        }
        if str_eq(e.op, "%") or str_eq(e.op, "//") or
           str_eq(e.op, "&") or str_eq(e.op, "|") or
           str_eq(e.op, "^") or str_eq(e.op, "<<") or str_eq(e.op, ">>") {
            return "int"
        }
        if str_eq(e.op, "+") {
            if str_eq(lk, "str") and str_eq(rk, "str") {
                return "str"
            }
            if str_eq(lk, "str") {
                sema_error(s, e.lhs.get(0).line, e.lhs.get(0).col,
                           "operator '+' cannot concatenate str with `" +
                           sema_type_name(rk, "") + "`")
                return "error"
            }
            if str_eq(rk, "str") {
                sema_error(s, e.lhs.get(0).line, e.lhs.get(0).col,
                           "operator '+' cannot concatenate `" +
                           sema_type_name(lk, "") + "` with str")
                return "error"
            }
        }
        if str_eq(lk, "float") or str_eq(rk, "float") {
            return "float"
        }
        return lk
    }
    if e.kind == ExprCall() {
        # Generic construction: List[int]() / Map[str,int]() / Box[int]()
        if e.type_args.len() > 0 {
            ctor_tkey = sema_resolve_type_key(s, e.name, e.line, e.col)
            if s.generic_classes.contains(ctor_tkey) {
                if str_eq(e.name, "Task") {
                    sema_error(s, e.line, e.col,
                               "Task values can only be created by calling an async function")
                    i = 0
                    while i < e.args.len() {
                        sema_check_expr(s, e.args.get(i))
                        i = i + 1
                    }
                    return "custom"
                }
                encs = List[str]()
                i = 0
                while i < e.type_args.len() {
                    encs.push(sema_encode_type(s, e.type_args.get(i)))
                    i = i + 1
                }
                inst = sema_instantiate_class(s, ctor_tkey, encs, e.line, e.col)
                if inst.len() == 0 {
                    sema_error(s, e.line, e.col, "call to unknown function `" + e.name + "`")
                    return "error"
                }
                s.last_generic_custom = inst
                i = 0
                while i < e.args.len() {
                    sema_check_expr(s, e.args.get(i))
                    i = i + 1
                }
                return "custom"
            }
            if s.generic_enums.contains(ctor_tkey) {
                encs = List[str]()
                i = 0
                while i < e.type_args.len() {
                    encs.push(sema_encode_type(s, e.type_args.get(i)))
                    i = i + 1
                }
                inst = sema_instantiate_enum(s, ctor_tkey, encs, e.line, e.col)
                s.last_generic_custom = inst
                return "custom"
            }
            return "custom"
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            ta = e.object.get(0)
            ta_tkey = sema_resolve_type_key(s, ta.ta_name, e.line, e.col)
            if s.generic_enums.contains(ta_tkey) {
                encs = List[str]()
                i = 0
                while i < ta.ta_args.len() {
                    encs.push(sema_encode_type(s, ta.ta_args.get(i)))
                    i = i + 1
                }
                inst = sema_instantiate_enum(s, ta_tkey, encs, e.line, e.col)
                if inst.len() == 0 {
                    return "error"
                }
                s.last_generic_custom = inst
                sema_check_enum_variant_args(s, @e, inst)
                return "custom"
            }
            if str_eq(ta.ta_name, "Maybe") or str_eq(ta.ta_name, "Result") {
                # Built-in generic enum: instance name = Maybe$<resolved argument mangled>.
                inst = ta.ta_name
                ai = 0
                while ai < ta.ta_args.len() {
                    inst = inst + "$" + sema_env_display(sema_encode_type(s, ta.ta_args.get(ai)))
                    ai = ai + 1
                }
                sema_register_builtin_enum(s, inst)
                sema_check_enum_variant_args(s, @e, inst)
                return "custom"
            }
            return "custom"
        }
        # Module-qualified calls: module.func(...)
        if e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            mod_name = e.object.get(0).name
            mod_canon = sema_module_canonical(s, mod_name)
            mod_tkey = sema_resolve_type_key(s, mod_name, e.line, e.col)
            mod_is_value = s.cur_locals.contains(mod_name) or
                           s.class_fields.contains(mod_tkey) or
                           s.enum_variants.contains(mod_tkey)
            if not mod_is_value {
                exp_key = mod_canon + "." + e.name
                alias = ""
                if s.module_exports.contains(exp_key) {
                    alias = s.module_exports.get(exp_key)
                } else {
                    alias = sema_module_builtin_alias(mod_name, e.name)
                }
                if alias.len() == 0 {
                    # Qualified call to a generic template: module.GenericFn(...)
                    gq = mod_canon + "$" + e.name
                    if s.generic_fns.contains(gq) {
                        return sema_generic_fn_call(s, @e, gq)
                    }
                }
                if alias.len() > 0 {
                    s.qualified_calls.put(sema_call_key(s, @e), alias)
                    if s.fn_ret_kinds.contains(alias) {
                        s.call_syms.put(sema_call_key(s, @e), alias)
                    }
                    if str_eq(alias, "asyncio.run") {
                        return sema_check_asyncio_run(s, @e)
                    }
                    if str_eq(alias, "asyncio.gather") {
                        return sema_check_asyncio_gather(s, @e)
                    }
                    if str_eq(alias, "asyncio.wait_any") {
                        return sema_check_asyncio_wait_any(s, @e)
                    }
                    if str_eq(alias, "asyncio.cancelled") {
                        return sema_check_asyncio_cancelled(s, @e)
                    }
                    if alias.startswith("math.") {
                        return sema_check_math_call(s, @e, alias.slice(5, alias.len()))
                    }
                    sema_check_call_args(s, @e, "function", exp_key,
                                         s.fn_param_kinds.get(alias),
                                         s.fn_param_customs.get(alias), 0)
                    if s.async_fns.contains(alias) {
                        sema_async_task_of_fn(s, alias, e.line, e.col)
                        return "custom"
                    }
                    return s.fn_ret_kinds.get(alias)
                }
                if s.module_names.contains(mod_canon) {
                    sema_error(s, e.line, e.col, "module `" + mod_name +
                               "` has no public function `" + e.name + "`")
                    return "error"
                }
            }
        }
        if e.object.len() > 0 {
            # Method calls.
            obj_kind = sema_check_expr(s, e.object.get(0))
            obj_custom = sema_expr_custom(s, e.object.get(0))
            mname = obj_custom + "$" + e.name
            if s.fn_ret_kinds.contains(mname) {
                sema_check_call_args(s, @e, "method", e.name,
                                     s.fn_param_kinds.get(mname),
                                     s.fn_param_customs.get(mname), 1)
                return s.fn_ret_kinds.get(mname)
            }
            if obj_custom.startswith("List$") and str_eq(e.name, "contains") {
                elem = obj_custom.slice(5, obj_custom.len())
                if str_eq(elem_kind_of_mangled(elem), "custom") {
                    sema_error(s, e.object.get(0).line, e.object.get(0).col,
                               "List.contains() is not supported for custom element type `" +
                               elem + "` yet")
                }
            }
            if obj_custom.startswith("Task$") and str_eq(e.name, "wait") {
                if e.args.len() != 1 {
                    sema_error(s, e.line, e.col,
                               "Task.wait() expects 1 argument (milliseconds)")
                    return "error"
                }
                ak = sema_check_expr(s, e.args.get(0))
                ac = sema_expr_custom(s, e.args.get(0))
                if not str_eq(ak, "int") {
                    sema_error(s, e.args.get(0).line, e.args.get(0).col,
                               "Task.wait() expects int milliseconds, found `" +
                               sema_type_name(ak, ac) + "`")
                }
                return "bool"
            }
            if obj_custom.startswith("Task$") and
               (str_eq(e.name, "cancel") or str_eq(e.name, "cancelled")) {
                if e.args.len() != 0 {
                    sema_error(s, e.line, e.col,
                               "Task." + e.name + "() takes no arguments")
                    return "error"
                }
                return "bool"
            }
            # Built-in methods also need argument checks: their nested calls must be resolved and recorded in call_syms,
            # otherwise IR can only fall back to bare names and cannot emit calls to module functions.
            sema_check_builtin_method_args(s, @e, obj_kind, obj_custom)
            return sema_builtin_method_kind(s, e.object.get(0), obj_kind, obj_custom, e.name)
        }
        # Free-function calls.
        ctor_key = sema_resolve_type_key(s, e.name, e.line, e.col)
        if e.object.len() == 0 and s.class_fields.contains(ctor_key) {
            sema_check_type_visibility(s, ctor_key, e.line, e.col)
            i = 0
            while i < e.args.len() {
                sema_check_expr(s, e.args.get(i))
                i = i + 1
            }
            return "custom"
        }
        if e.object.len() == 0 and s.enum_variant_enum.contains(e.name) {
            enum_name = s.enum_variant_enum.get(e.name)
            sema_check_enum_variant_args(s, @e, enum_name)
            return "custom"
        }
        if str_eq(e.name, "print") {
            i = 0
            while i < e.args.len() {
                sema_check_expr(s, e.args.get(i))
                i = i + 1
            }
            return "None"
        }
        if str_eq(e.name, "to_string") {
            if e.args.len() != 1 {
                sema_error(s, e.line, e.col, "to_string() expects 1 argument")
                return "str"
            }
            ak = sema_check_expr(s, e.args.get(0))
            if not str_eq(ak, "int") and not str_eq(ak, "float") and
               not str_eq(ak, "bool") {
                sema_error(s, e.args.get(0).line, e.args.get(0).col,
                           "to_string() expects int/float/bool, found `" + ak + "`")
            }
            return "str"
        }
        if str_eq(e.name, "chr") {
            if e.args.len() != 1 {
                sema_error(s, e.line, e.col, "chr() expects 1 argument")
                return "str"
            }
            ak = sema_check_expr(s, e.args.get(0))
            if not str_eq(ak, "int") {
                sema_error(s, e.args.get(0).line, e.args.get(0).col,
                           "chr() expects int, found `" + ak + "`")
            }
            return "str"
        }
        if str_eq(e.name, "format") {
            return sema_check_format(s, @e)
        }
        if str_eq(e.name, "args") {
            if e.args.len() != 0 {
                sema_error(s, e.line, e.col, "args() expects 0 arguments")
            }
            return "custom"
        }
        if str_eq(e.name, "system") or str_eq(e.name, "read_file") or
           str_eq(e.name, "remove_file") or str_eq(e.name, "exists") or
           str_eq(e.name, "write_stderr") {
            if e.args.len() != 1 {
                sema_error(s, e.line, e.col, e.name + "() expects 1 argument")
            } else {
                sema_check_expr(s, e.args.get(0))
            }
            return sema_builtin_fn_kind(s, e.name)
        }
        if str_eq(e.name, "write_file") or str_eq(e.name, "append_file") {
            if e.args.len() != 2 {
                sema_error(s, e.line, e.col, e.name + "() expects 2 arguments")
            } else {
                sema_check_expr(s, e.args.get(0))
                sema_check_expr(s, e.args.get(1))
            }
            return sema_builtin_fn_kind(s, e.name)
        }
        if str_eq(e.name, "range") {
            sema_error(s, e.line, e.col, "range() can only be used as a for-loop iterable")
            i = 0
            while i < e.args.len() {
                sema_check_expr(s, e.args.get(i))
                i = i + 1
            }
            return "custom"
        }
        before_err = s.diag_errors
        fn_key = sema_resolve_fn_key(s, e.name, e.line, e.col)
        if fn_key.len() > 0 {
            if s.generic_fns.contains(fn_key) {
                return sema_generic_fn_call(s, @e, fn_key)
            }
            # Record the resolution result: the IR side emits calls by physical symbol name.
            s.call_syms.put(sema_call_key(s, @e), fn_key)
            sema_check_call_args(s, @e, "function", e.name,
                                 s.fn_param_kinds.get(fn_key),
                                 s.fn_param_customs.get(fn_key), 0)
            if s.async_fns.contains(fn_key) {
                sema_async_task_of_fn(s, fn_key, e.line, e.col)
                return "custom"
            }
            return s.fn_ret_kinds.get(fn_key)
        }
        if s.diag_errors > before_err {
            return "error"
        }
        # math builtins allow omitting the module prefix; user functions with the same name take priority.
        if sema_is_math_builtin(e.name) {
            return sema_check_math_call(s, @e, e.name)
        }
        if s.private_fns.contains(e.name) {
            owner = s.private_fns.get(e.name)
            if not str_eq(s.current_module, owner) {
                sema_error(s, e.line, e.col, "symbol `" + e.name +
                           "` is private to module `" + owner + "`")
                return "error"
            }
        }
        sema_error(s, e.line, e.col, "call to unknown function `" + e.name + "`")
        return "error"
    }
    if e.kind == ExprIf() {
        sema_check_expr(s, e.cond.get(0))
        before = sema_save_state(s)
        first_kind = "None"
        first_custom = ""
        if e.then_block.len() > 0 {
            first_kind = sema_check_expr(s, e.then_block.get(0))
            first_custom = sema_expr_custom(s, e.then_block.get(0))
        }
        after_then = sema_save_state(s)
        sema_restore_state(s, before)
        if e.else_block.len() > 0 {
            ek = sema_check_expr(s, e.else_block.get(0))
            ec = sema_expr_custom(s, e.else_block.get(0))
            one_none = str_eq(first_kind, "None") or str_eq(ek, "None")
            if s.in_expr_stmt == 0 and
               not str_eq(first_kind, "error") and not str_eq(ek, "error") and
               not one_none and
               not sema_can_assign(ek, ec, first_kind, first_custom) and
               not sema_can_assign(first_kind, first_custom, ek, ec) {
                sema_error(s, e.line, e.col,
                           "if branches have mismatched types: `" +
                           sema_type_name(first_kind, first_custom) + "` vs `" +
                           sema_type_name(ek, ec) + "`")
            }
            if str_eq(first_kind, "None") and not str_eq(ek, "error") {
                first_kind = ek
                first_custom = ec
            }
        }
        sema_merge_state(s, after_then)
        return first_kind
    }
    if e.kind == ExprBlock() {
        bi = 0
        while bi < e.stmts.len() {
            sema_check_stmt(s, e.stmts.get(bi))
            bi = bi + 1
        }
        if e.result.len() > 0 {
            return sema_check_expr(s, e.result.get(0))
        }
        return "None"
    }
    if e.kind == ExprAssign() {
        if e.target.len() > 0 {
            tg = e.target.get(0)
            nobj = tg.object.get(0)
            if nobj.kind == ExprVar() and s.cur_borrow_target.contains(nobj.name) and
               s.cur_borrow_target.get(nobj.name).len() > 0 and
               s.cur_handle_mut.get(nobj.name) == 0 {
                sema_error(s, nobj.line, nobj.col,
                           "cannot assign through shared borrow `" + nobj.name + "`")
            } else {
                sema_check_expr(s, tg.object.get(0))
            }
            vk = sema_check_expr(s, e.value.get(0))
            return vk
        }
        vk = sema_check_expr(s, e.value.get(0))
        vc = sema_expr_custom(s, e.value.get(0))
        ve = e.value.get(0)
        if ve.kind == ExprVar() and s.cur_borrow_target.contains(ve.name) and
           s.cur_borrow_target.get(ve.name).len() > 0 {
            sema_error(s, e.line, e.col,
                       "cannot copy a borrow handle; create a new borrow with `@` or `@var`")
        }
        dk = vk
        dc = vc
        if e.type_ann.name.len() > 0 {
            denc = sema_encode_type(s, e.type_ann)
            dk = sema_env_kind(denc)
            dc = sema_env_custom(denc)
            if not sema_can_assign(vk, vc, dk, dc) {
                sema_error(s, ve.line, ve.col, "type mismatch: expected `" +
                           sema_type_name(dk, dc) + "`, found `" +
                           sema_type_name(vk, vc) + "`")
            }
        }
        if s.cur_locals.contains(e.name) {
            s.cur_moved.put(e.name, 0)
            s.cur_borrow_target.put(e.name, "")
            s.cur_handle_mut.put(e.name, 0)
            s.cur_locals.put(e.name, dk)
            s.cur_local_customs.put(e.name, dc)
        } else {
            sema_declare_var(s, e.name, dk, dc)
        }
        if ve.kind == ExprBorrow() {
            op = ve.operand.get(0)
            if op.kind == ExprVar() {
                s.cur_borrow_target.put(e.name, op.name)
                if ve.is_mut {
                    s.cur_handle_mut.put(e.name, 1)
                } else {
                    s.cur_handle_mut.put(e.name, 0)
                }
            }
        } elif str_eq(vk, "custom") and ve.kind == ExprVar() {
            if sema_shared_count(s, ve.name) > 0 or sema_mut_count(s, ve.name) > 0 {
                sema_error(s, ve.line, ve.col, "cannot move out of `" + ve.name +
                           "` because it is borrowed")
            } elif not (s.cur_borrow_target.get(ve.name).len() > 0) {
                sema_mark_moved(s, ve.name)
            }
        }
        return dk
    }
    if e.kind == ExprMember() {
        obj_kind = sema_check_expr(s, e.object.get(0))
        obj_custom = sema_expr_custom(s, e.object.get(0))
        if obj_custom.len() == 0 {
            if not str_eq(obj_kind, "error") {
                sema_error(s, e.line, e.col,
                           "cannot access member `" + e.name + "` on non-class value")
            }
            return "error"
        }
        if s.enum_variants.contains(obj_custom) {
            sema_error(s, e.line, e.col,
                       "cannot access member `" + e.name + "` on enum `" + obj_custom + "`")
            return "error"
        }
        if not s.class_fields.contains(obj_custom) {
            sema_error(s, e.line, e.col,
                       "unknown field `" + e.name + "` in class `" + obj_custom + "`")
            return "error"
        }
        names = s.class_fields.get(obj_custom).split(",")
        found = False
        i = 0
        while i < names.len() {
            if str_eq(names.get(i), e.name) {
                found = True
            }
            i = i + 1
        }
        if not found {
            sema_error(s, e.object.get(0).line, e.object.get(0).col,
                       "unknown field `" + e.name + "` in class `" + obj_custom + "`")
            return "error"
        }
        return sema_member_kind(s, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        subject_kind = sema_check_expr(s, e.subject.get(0))
        subject_custom = sema_expr_custom(s, e.subject.get(0))
        if subject_custom.startswith("Maybe$") or subject_custom.startswith("Result$") {
            sema_register_builtin_enum(s, subject_custom)
        }
        first_kind = "None"
        first_custom = ""
        has_first = False
        i = 0
        while i < e.arms.len() {
            arm = e.arms.get(i)
            p = arm.pattern
            if p.kind == PatternVariant() {
                v_idx = -1
                if subject_custom.len() > 0 {
                    v_idx = sema_match_variant_idx(s, subject_custom, p.name)
                }
                if v_idx < 0 {
                    sema_error(s, e.line, e.col, "unknown variant `" + p.name +
                               "` of enum `" + subject_custom + "`")
                } else {
                    sema_bind_pattern(s, p, subject_custom, v_idx,
                                      subject_kind, subject_custom, e.line, e.col)
                }
            } elif p.kind == PatternVar() {
                sema_declare_var(s, p.name, subject_kind, subject_custom)
            }
            bk = sema_check_expr(s, arm.body)
            bc = sema_expr_custom(s, arm.body)
            if not has_first {
                first_kind = bk
                first_custom = bc
                has_first = True
            } elif not str_eq(bk, "error") and not str_eq(first_kind, "error") and
                   (not str_eq(bk, first_kind) or
                    (str_eq(bk, "custom") and not str_eq(bc, first_custom))) {
                sema_error(s, arm.body.line, arm.body.col,
                           "match arms have mismatched types: `" +
                           sema_type_name(first_kind, first_custom) + "` vs `" +
                           sema_type_name(bk, bc) + "`")
            }
            i = i + 1
        }
        return first_kind
    }
    return "error"
}

# Get the custom type name of an expression (returns "" when not custom).
public def sema_expr_custom(s: @var Sema, e: Expr) -> str {
    if e.kind == ExprVar() {
        if s.cur_local_customs.contains(e.name) {
            return s.cur_local_customs.get(e.name)
        }
        return ""
    }
    if e.kind == ExprCall() {
        qn = sema_qualified_name(s, @e)
        if qn.len() == 0 and e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            mod_name = e.object.get(0).name
            mod_canon2 = sema_module_canonical(s, mod_name)
            mod_tkey2 = sema_resolve_type_key(s, mod_name, e.line, e.col)
            mod_is_value = s.cur_locals.contains(mod_name) or
                           s.class_fields.contains(mod_tkey2) or
                           s.enum_variants.contains(mod_tkey2)
            if not mod_is_value {
                exp_key = mod_canon2 + "." + e.name
                if s.module_exports.contains(exp_key) {
                    qn = s.module_exports.get(exp_key)
                } else {
                    qn = sema_module_builtin_alias(mod_name, e.name)
                }
            }
        }
        if qn.len() > 0 {
            if str_eq(qn, "asyncio.run") {
                if e.args.len() == 1 {
                    return sema_task_payload_custom(sema_expr_custom(s, e.args.get(0)))
                }
                return ""
            }
            if str_eq(qn, "asyncio.gather") {
                if e.args.len() == 1 {
                    c0 = sema_expr_custom(s, e.args.get(0))
                    if c0.startswith("List$Task$") {
                        p0 = sema_task_payload(c0.slice(5, c0.len()))
                        return "Task$List$" + p0
                    }
                }
                return ""
            }
            if s.async_fns.contains(qn) {
                return sema_task_type(s.fn_ret_kinds.get(qn), s.fn_ret_customs.get(qn))
            }
            if s.fn_ret_customs.contains(qn) {
                return s.fn_ret_customs.get(qn)
            }
            return ""
        }
        if e.type_args.len() > 0 {
            cu_tkey = sema_resolve_type_key(s, e.name, e.line, e.col)
            if s.generic_classes.contains(cu_tkey) {
                encs = List[str]()
                i = 0
                while i < e.type_args.len() {
                    encs.push(sema_encode_type(s, e.type_args.get(i)))
                    i = i + 1
                }
                return sema_instantiate_class(s, cu_tkey, encs, e.line, e.col)
            }
            if s.generic_enums.contains(cu_tkey) {
                encs = List[str]()
                i = 0
                while i < e.type_args.len() {
                    encs.push(sema_encode_type(s, e.type_args.get(i)))
                    i = i + 1
                }
                return sema_instantiate_enum(s, cu_tkey, encs, e.line, e.col)
            }
            if str_eq(e.name, "List") or str_eq(e.name, "Maybe") {
                return e.name + "$" + sema_env_display(sema_encode_type(s, e.type_args.get(0)))
            }
            if str_eq(e.name, "Map") or str_eq(e.name, "Result") {
                return e.name + "$" + sema_env_display(sema_encode_type(s, e.type_args.get(0))) + "$" +
                       sema_env_display(sema_encode_type(s, e.type_args.get(1)))
            }
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            ta = e.object.get(0)
            cu_tkey2 = sema_resolve_type_key(s, ta.ta_name, e.line, e.col)
            if s.generic_enums.contains(cu_tkey2) {
                encs = List[str]()
                i = 0
                while i < ta.ta_args.len() {
                    encs.push(sema_encode_type(s, ta.ta_args.get(i)))
                    i = i + 1
                }
                return sema_instantiate_enum(s, cu_tkey2, encs, e.line, e.col)
            }
            if str_eq(ta.ta_name, "Maybe") or str_eq(ta.ta_name, "Result") {
                inst2 = ta.ta_name
                ai2 = 0
                while ai2 < ta.ta_args.len() {
                    inst2 = inst2 + "$" + sema_env_display(sema_encode_type(s, ta.ta_args.get(ai2)))
                    ai2 = ai2 + 1
                }
                return inst2
            }
            # Non-builtin TypeApply: build the mangled name from the resolved registration key + resolved arguments.
            inst3 = cu_tkey2
            ai3 = 0
            while ai3 < ta.ta_args.len() {
                inst3 = inst3 + "$" + sema_env_display(sema_encode_type(s, ta.ta_args.get(ai3)))
                ai3 = ai3 + 1
            }
            return inst3
        }
        ck = sema_call_key(s, @e)
        if s.call_syms.contains(ck) {
            fn_key = s.call_syms.get(ck)
            if s.async_fns.contains(fn_key) {
                return sema_task_type(s.fn_ret_kinds.get(fn_key),
                                      s.fn_ret_customs.get(fn_key))
            }
            if s.fn_ret_customs.contains(fn_key) {
                return s.fn_ret_customs.get(fn_key)
            }
            return ""
        }
        if s.generic_fns.contains(e.name) {
            return s.last_generic_custom
        }
        if e.object.len() > 0 {
            obj_custom = sema_expr_custom(s, e.object.get(0))
            mname = obj_custom + "$" + e.name
            if s.fn_ret_customs.contains(mname) {
                return s.fn_ret_customs.get(mname)
            }
            return sema_builtin_method_custom(e.object.get(0), obj_custom, e.name)
        }
        vkey = sema_resolve_type_key(s, e.name, e.line, e.col)
        if s.class_fields.contains(vkey) {
            return vkey
        }
        if s.enum_variant_enum.contains(e.name) {
            return s.enum_variant_enum.get(e.name)
        }
        if e.name == "args" {
            return "List$str"
        }
        if e.name == "read_file" {
            return "Result$str$str"
        }
        if e.name == "write_file" {
            return "Result$None$str"
        }
        if e.name == "range" {
            return "List$int"
        }
        fn_key = sema_resolve_fn_key(s, e.name, e.line, e.col)
        if fn_key.len() > 0 and s.async_fns.contains(fn_key) {
            return sema_task_type(s.fn_ret_kinds.get(fn_key),
                                  s.fn_ret_customs.get(fn_key))
        }
        if fn_key.len() > 0 and s.fn_ret_customs.contains(fn_key) {
            return s.fn_ret_customs.get(fn_key)
        }
        return ""
    }
    if e.kind == ExprAwait() {
        if e.operand.len() == 0 {
            return ""
        }
        return sema_task_payload_custom(sema_expr_custom(s, e.operand.get(0)))
    }
    if e.kind == ExprBorrow() {
        return sema_expr_custom(s, e.operand.get(0))
    }
    if e.kind == ExprTry() {
        ok = ""
        parts = sema_result_parts(sema_expr_custom(s, e.operand.get(0)))
        if parts.len() > 0 {
            ok = parts.get(0)
        }
        if str_eq(elem_kind_of_mangled(ok), "custom") {
            return ok
        }
        return ""
    }
    if e.kind == ExprAssign() {
        return sema_expr_custom(s, e.value.get(0))
    }
    if e.kind == ExprMember() {
        return sema_member_custom(s, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        if e.arms.len() > 0 {
            return sema_expr_custom(s, e.arms.get(0).body)
        }
        return ""
    }
    return ""
}

public def sema_builtin_fn_kind(s: @var Sema, name: str) -> str {
    if s.fn_ret_kinds.contains(name) {
        return s.fn_ret_kinds.get(name)
    }
    return "None"
}

# Scan a format literal (honoring `{{` / `}}` escapes), then validate each
# placeholder spec against the corresponding argument type.
public def sema_check_format(s: @var Sema, e: @Expr) -> str {
    if e.args.len() == 0 {
        sema_error(s, e.line, e.col, "format() expects at least 1 argument")
        return "str"
    }
    fmt = e.args.get(0)
    specs = List[str]()
    literal_ok = True
    if fmt.kind != ExprStringLit() {
        sema_error(s, fmt.line, fmt.col, "format() expects a string literal as its first argument")
        literal_ok = False
    } else {
        text = fmt.str_val
        i = 0
        while i < text.len() {
            c = text.char_at(i)
            if c == "{".char_at(0) {
                if i + 1 < text.len() and text.char_at(i + 1) == "{".char_at(0) {
                    i = i + 2
                } else {
                    j = i + 1
                    while j < text.len() and text.char_at(j) != "}".char_at(0) {
                        j = j + 1
                    }
                    if j >= text.len() {
                        sema_error(s, fmt.line, fmt.col, "unmatched `{` in format string")
                        i = text.len()
                    } else {
                        specs.push(text.slice(i + 1, j))
                        i = j + 1
                    }
                }
            } elif c == "}".char_at(0) {
                if i + 1 < text.len() and text.char_at(i + 1) == "}".char_at(0) {
                    i = i + 2
                } else {
                    sema_error(s, fmt.line, fmt.col, "unmatched `}` in format string")
                    i = i + 1
                }
            } else {
                i = i + 1
            }
        }
        want = e.args.len() - 1
        if specs.len() != want {
            sema_error(s, e.line, e.col, "format() expects " + to_string(specs.len()) +
                       " placeholder argument(s), found " + to_string(want))
        }
    }
    kinds = List[str]()
    i = 1
    while i < e.args.len() {
        ak = sema_check_expr(s, e.args.get(i))
        kinds.push(ak)
        if not str_eq(ak, "int") and not str_eq(ak, "float") and
           not str_eq(ak, "bool") and not str_eq(ak, "str") {
            sema_error(s, e.args.get(i).line, e.args.get(i).col,
                       "format() argument must be int/float/bool/str, found `" + ak + "`")
        }
        i = i + 1
    }
    if literal_ok {
        i = 0
        while i < specs.len() and i < kinds.len() {
            k = kinds.get(i)
            if str_eq(k, "int") or str_eq(k, "float") or str_eq(k, "bool") or str_eq(k, "str") {
                info = sema_format_spec_parse(specs.get(i), k)
                if not info.ok {
                    sema_error(s, fmt.line, fmt.col, info.error)
                }
            }
            i = i + 1
        }
    }
    return "str"
}

# math builtins: abs/min/max/sqrt/pow/floor/ceil, numeric arguments, returning int/float.
public def sema_check_math_call(s: @var Sema, e: @Expr, name: str) -> str {
    want = 1
    if str_eq(name, "pow") or str_eq(name, "min") or str_eq(name, "max") {
        want = 2
    }
    k0 = "int"
    k1 = "int"
    if e.args.len() != want {
        sema_error(s, e.line, e.col, name + "() expects " + to_string(want) + " argument(s)")
        i = 0
        while i < e.args.len() {
            sema_check_expr(s, e.args.get(i))
            i = i + 1
        }
    } else {
        i = 0
        while i < e.args.len() {
            k = sema_check_expr(s, e.args.get(i))
            if not sema_is_num_kind(k) {
                sema_error(s, e.args.get(i).line, e.args.get(i).col,
                           name + "() expects int/float, found `" + k + "`")
            }
            if i == 0 {
                k0 = k
            } else {
                k1 = k
            }
            i = i + 1
        }
    }
    if str_eq(name, "abs") {
        if str_eq(k0, "float") {
            return "float"
        }
        return "int"
    }
    if str_eq(name, "min") or str_eq(name, "max") {
        if str_eq(k0, "float") or str_eq(k1, "float") {
            return "float"
        }
        return "int"
    }
    return "float"
}

# Built-in method argument checks (arity + argument kinds).
def sema_method_arity(s: @var Sema, e: @Expr, want: int) -> bool {
    if e.args.len() != want {
        sema_error(s, e.line, e.col, e.name + "() expects " + to_string(want) +
                   " argument(s), found " + to_string(e.args.len()))
        return False
    }
    return True
}

def sema_method_want_kind(s: @var Sema, e: @Expr, idx: int, want: str, kinds: @List[str]) {
    if idx < kinds.len() and not str_eq(kinds.get(idx), want) {
        # int literals/values promote to float in numeric containers.
        if str_eq(want, "float") and str_eq(kinds.get(idx), "int") {
            return
        }
        sema_error(s, e.args.get(idx).line, e.args.get(idx).col,
                   e.name + "() argument " + to_string(idx + 1) + " expects " + want +
                   ", found `" + kinds.get(idx) + "`")
    }
}

def sema_method_want_custom(s: @var Sema, e: @Expr, idx: int, want: str) {
    if idx < e.args.len() {
        got = sema_expr_custom(s, e.args.get(idx))
        if not str_eq(got, want) {
            sema_error(s, e.args.get(idx).line, e.args.get(idx).col,
                       e.name + "() argument " + to_string(idx + 1) + " expects `" +
                       want + "`, found `" + got + "`")
        }
    }
}

def sema_method_want_list_elem(s: @var Sema, e: @Expr, idx: int, elem: str, kinds: @List[str]) {
    eks = elem_kind_of_mangled(elem)
    if str_eq(eks, "custom") {
        sema_method_want_custom(s, e, idx, elem)
    } elif idx < kinds.len() and not str_eq(kinds.get(idx), eks) {
        if not (str_eq(eks, "float") and str_eq(kinds.get(idx), "int")) {
            sema_error(s, e.args.get(idx).line, e.args.get(idx).col,
                       e.name + "() argument " + to_string(idx + 1) + " expects " + eks +
                       ", found `" + kinds.get(idx) + "`")
        }
    }
}

public def sema_check_builtin_method_args(s: @var Sema, e: @Expr, obj_kind: str, obj_custom: str) {
    kinds = List[str]()
    ai = 0
    while ai < e.args.len() {
        kinds.push(sema_check_expr(s, e.args.get(ai)))
        ai = ai + 1
    }
    m = e.name
    if str_eq(obj_kind, "str") {
        if str_eq(m, "len") or str_eq(m, "trim") or str_eq(m, "trim_start") or
           str_eq(m, "trim_end") or str_eq(m, "lines") or
           str_eq(m, "to_int") or str_eq(m, "to_float") {
            sema_method_arity(s, e, 0)
        } elif str_eq(m, "contains") or str_eq(m, "startswith") or str_eq(m, "endswith") or
             str_eq(m, "find") or str_eq(m, "rfind") or str_eq(m, "split") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_kind(s, e, 0, "str", @kinds)
            }
        } elif str_eq(m, "char_at") or str_eq(m, "repeat") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_kind(s, e, 0, "int", @kinds)
            }
        } elif str_eq(m, "slice") {
            if sema_method_arity(s, e, 2) {
                sema_method_want_kind(s, e, 0, "int", @kinds)
                sema_method_want_kind(s, e, 1, "int", @kinds)
            }
        } elif str_eq(m, "replace") {
            if sema_method_arity(s, e, 2) {
                sema_method_want_kind(s, e, 0, "str", @kinds)
                sema_method_want_kind(s, e, 1, "str", @kinds)
            }
        } elif str_eq(m, "join") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_custom(s, e, 0, "List$str")
            }
        }
    } elif obj_custom.startswith("List$") {
        elem = obj_custom.slice(5, obj_custom.len())
        if str_eq(m, "len") or str_eq(m, "pop") or str_eq(m, "clear") or
           str_eq(m, "reverse") {
            sema_method_arity(s, e, 0)
        } elif str_eq(m, "get") or str_eq(m, "remove_at") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_kind(s, e, 0, "int", @kinds)
            }
        } elif str_eq(m, "push") or str_eq(m, "contains") or str_eq(m, "index_of") or
             str_eq(m, "remove") {
            if sema_method_arity(s, e, 1) {
                if (str_eq(m, "contains") or str_eq(m, "index_of") or str_eq(m, "remove")) and
                   str_eq(elem_kind_of_mangled(elem), "custom") {
                    sema_error(s, e.line, e.col, "List." + m +
                               "() is not supported for custom element type `" + elem + "` yet")
                } elif not str_eq(elem_kind_of_mangled(elem), "custom") {
                    sema_method_want_kind(s, e, 0, elem_kind_of_mangled(elem), @kinds)
                } else {
                    sema_method_want_custom(s, e, 0, elem)
                }
            }
        } elif str_eq(m, "set") or str_eq(m, "insert") {
            if sema_method_arity(s, e, 2) {
                sema_method_want_kind(s, e, 0, "int", @kinds)
                sema_method_want_list_elem(s, e, 1, elem, @kinds)
            }
        }
    } elif obj_custom.startswith("Map$") {
        rest = obj_custom.slice(4, obj_custom.len())
        d = str_find(rest, "$")
        key = rest.slice(0, d)
        val = rest.slice(d + 1, rest.len())
        if str_eq(m, "len") or str_eq(m, "keys") or str_eq(m, "values") {
            sema_method_arity(s, e, 0)
        } elif str_eq(m, "contains") or str_eq(m, "get") or str_eq(m, "remove") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_list_elem(s, e, 0, key, @kinds)
            }
        } elif str_eq(m, "put") {
            if sema_method_arity(s, e, 2) {
                sema_method_want_list_elem(s, e, 0, key, @kinds)
                sema_method_want_list_elem(s, e, 1, val, @kinds)
            }
        }
    } elif obj_custom.startswith("Maybe$") or obj_custom.startswith("Result$") {
        if str_eq(m, "is_some") or str_eq(m, "is_nothing") or
           str_eq(m, "is_ok") or str_eq(m, "is_err") or str_eq(m, "unwrap") {
            sema_method_arity(s, e, 0)
        } elif str_eq(m, "expect") {
            if sema_method_arity(s, e, 1) {
                sema_method_want_kind(s, e, 0, "str", @kinds)
            }
        }
    } elif obj_custom.startswith("Task$") {
        if str_eq(m, "done") {
            sema_method_arity(s, e, 0)
        }
    }
}

# Built-in method return kinds.
public def sema_builtin_method_kind(s: @var Sema, obj: Expr, obj_kind: str, obj_custom: str, m: str) -> str {
    if str_eq(obj_kind, "str") {
        if str_eq(m, "len") or str_eq(m, "char_at") or
           str_eq(m, "find") or str_eq(m, "rfind") {
            return "int"
        }
        if str_eq(m, "to_int") or str_eq(m, "to_float") {
            return "custom"
        }
        if str_eq(m, "contains") or str_eq(m, "startswith") or str_eq(m, "endswith") {
            return "bool"
        }
        if str_eq(m, "slice") or str_eq(m, "join") or str_eq(m, "trim") or
           str_eq(m, "trim_start") or str_eq(m, "trim_end") or
           str_eq(m, "replace") or str_eq(m, "repeat") {
            return "str"
        }
        if str_eq(m, "split") or str_eq(m, "lines") {
            return "custom"
        }
        return "None"
    }
    if obj_custom.startswith("List$") {
        if str_eq(m, "len") or str_eq(m, "index_of") {
            return "int"
        }
        if str_eq(m, "contains") or str_eq(m, "remove") {
            return "bool"
        }
        if str_eq(m, "push") or str_eq(m, "set") or str_eq(m, "clear") or
           str_eq(m, "insert") or str_eq(m, "reverse") {
            return "None"
        }
        if str_eq(m, "pop") or str_eq(m, "get") or str_eq(m, "remove_at") {
            elem = obj_custom.slice(5, obj_custom.len())
            return elem_kind_of_mangled(elem)
        }
        return "None"
    }
    if obj_custom.startswith("Map$") {
        if str_eq(m, "len") {
            return "int"
        }
        if str_eq(m, "contains") or str_eq(m, "remove") {
            return "bool"
        }
        if str_eq(m, "get") {
            rest = obj_custom.slice(4, obj_custom.len())
            d = str_find(rest, "$")
            return elem_kind_of_mangled(rest.slice(d + 1, rest.len()))
        }
        if str_eq(m, "put") {
            return "None"
        }
        if str_eq(m, "keys") or str_eq(m, "values") {
            return "custom"
        }
        return "None"
    }
    if obj_custom.startswith("Task$") {
        if str_eq(m, "done") {
            return "bool"
        }
        if str_eq(m, "wait") {
            return "bool"
        }
        if str_eq(m, "cancel") or str_eq(m, "cancelled") {
            return "bool"
        }
        return "None"
    }
    if obj_custom.startswith("Maybe$") or obj_custom.startswith("Result$") {
        if str_eq(m, "is_some") or str_eq(m, "is_nothing") or
           str_eq(m, "is_ok") or str_eq(m, "is_err") {
            return "bool"
        }
        if str_eq(m, "unwrap") or str_eq(m, "expect") {
            first = obj_custom.slice(str_find(obj_custom, "$") + 1, obj_custom.len())
            d = str_find(first, "$")
            if d >= 0 {
                first = first.slice(0, d)
            }
            return elem_kind_of_mangled(first)
        }
        return "None"
    }
    return "None"
}

# Built-in method return custom type names.
public def sema_builtin_method_custom(obj: Expr, obj_custom: str, m: str) -> str {
    if obj_custom.startswith("List$") and
       (str_eq(m, "get") or str_eq(m, "pop") or str_eq(m, "remove_at")) {
        elem = obj_custom.slice(5, obj_custom.len())
        if str_eq(elem_kind_of_mangled(elem), "custom") {
            return elem
        }
        return ""
    }
    if obj_custom.startswith("Map$") and (str_eq(m, "get") or str_eq(m, "values")) {
        rest = obj_custom.slice(4, obj_custom.len())
        d = str_find(rest, "$")
        elem = rest.slice(d + 1, rest.len())
        if str_eq(m, "values") {
            return "List$" + elem
        }
        if str_eq(elem_kind_of_mangled(elem), "custom") {
            return elem
        }
        return ""
    }
    if obj_custom.startswith("Map$") and str_eq(m, "keys") {
        rest = obj_custom.slice(4, obj_custom.len())
        d = str_find(rest, "$")
        return "List$" + rest.slice(0, d)
    }
    if str_eq(obj_custom, "") and str_eq(m, "lines") {
        return "List$str"
    }
    if (obj_custom.startswith("Maybe$") or obj_custom.startswith("Result$")) and
       (str_eq(m, "unwrap") or str_eq(m, "expect")) {
        first = obj_custom.slice(str_find(obj_custom, "$") + 1, obj_custom.len())
        d = str_find(first, "$")
        if d >= 0 {
            first = first.slice(0, d)
        }
        if str_eq(elem_kind_of_mangled(first), "custom") {
            return first
        }
        return ""
    }
    if obj_custom.startswith("List$") and str_eq(m, "split") {
        return "List$str"
    }
    if str_eq(obj_custom, "") and str_eq(m, "to_int") {
        return "Result$int$str"
    }
    if str_eq(obj_custom, "") and str_eq(m, "to_float") {
        return "Result$float$str"
    }
    if str_eq(m, "split") {
        return "List$str"
    }
    return ""
}

# Mangled element name -> kind name.
public def elem_kind_of_mangled(name: str) -> str {
    if str_eq(name, "int") { return "int" }
    if str_eq(name, "float") { return "float" }
    if str_eq(name, "bool") { return "bool" }
    if str_eq(name, "str") { return "str" }
    if str_eq(name, "None") { return "None" }
    return "custom"
}

# Member access types.
public def sema_member_kind(s: @var Sema, obj: Expr, member: str) -> str {
    obj_custom = sema_expr_custom(s, obj)
    if obj_custom.len() == 0 {
        return "error"
    }
    if not s.class_fields.contains(obj_custom) {
        return "error"
    }
    fields = s.class_field_kinds.get(obj_custom).split(",")
    names = s.class_fields.get(obj_custom).split(",")
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), member) and i < fields.len() {
            return fields.get(i)
        }
        i = i + 1
    }
    return "error"
}

public def sema_member_custom(s: @var Sema, obj: Expr, member: str) -> str {
    obj_custom = sema_expr_custom(s, obj)
    if obj_custom.len() == 0 {
        return ""
    }
    if not s.class_fields.contains(obj_custom) {
        return ""
    }
    fields = s.class_field_types.get(obj_custom).split(",")
    names = s.class_fields.get(obj_custom).split(",")
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), member) and i < fields.len() {
            ft = fields.get(i)
            if ft.startswith("%") {
                return ft.slice(1, ft.len())
            }
            return ""
        }
        i = i + 1
    }
    return ""
}