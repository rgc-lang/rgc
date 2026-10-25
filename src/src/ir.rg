# RGC compiler: LLVM IR text generator
#
# Generates .ll text from the checked AST; the embedded LLVM produces an object file and g++ links an executable.
# Conventions:
#   int=i64, float=double, bool=i1, str=ptr(opaque), None=i64
#   List[T] = { ptr data, i64 len, i64 cap }
#   Map[K,V] = { %List$K keys, %List$V vals, ptr buckets, i64 nbuckets, i64 count, i64 used }
#     buckets: open-addressed i64 array; 0 = empty, -1 = tombstone, N > 0 = keys/vals index N-1.
#   class = { fields... } (stack struct, passed by value)
#   enum = { i8 disc, [N x i64] payload }
# Uses a plain alloca/load/store style, optimized by the LLVM O2 pipeline.

import util
import types
import ast
import token
import parser
import sema

public class IRGen {
    # output
    lines: List[str]
    reg: int
    label: int
    cur_fn: str
    cur_module: str
    fn_ret_llvm: str
    fn_ret_kind: str
    fn_ret_custom: str

    # local variables
    var_alloca: Map[str, str]
    var_kind: Map[str, str]
    var_type_name: Map[str, str]
    var_is_ptr: Map[str, int]     # 1 = variable stores a pointer to a custom type (self)

    # loop stack
    loop_continue: List[str]
    loop_exit: List[str]

    # registry (from Sema)
    class_order: List[str]
    class_fields: Map[str, str]
    class_field_types: Map[str, str]
    class_methods: Map[str, str]
    fn_order: List[str]
    fn_ret_llvm_map: Map[str, str]
    fn_ret_kinds: Map[str, str]
    fn_ret_customs: Map[str, str]
    fn_params_llvm: Map[str, str]
    fn_param_kinds: Map[str, str]
    fn_param_customs: Map[str, str]
    fn_is_extern: Map[str, int]     # 1 = extern def (call-site conversions for the C ABI)
    enum_order: List[str]
    enum_variants: Map[str, str]
    enum_payloads: Map[str, int]
    enum_variant_enum: Map[str, str]
    enum_variant_idx: Map[str, int]
    enum_field_kinds: Map[str, str]
    enum_field_names: Map[str, str]

    extra_stmts: List[Stmt]
    generic_fn_names: List[str]

    # module namespace: call-site resolution results and type-name resolution data (shared with Sema).
    call_syms: Map[str, str]
    module_types: Map[str, str]
    from_imports: Map[str, str]
    type_owners: Map[str, str]
    qualified_calls: Map[str, str]
    glob_imports: List[str]
    type_reexports: Map[str, str]

    # async: function name -> 1; thread wrapper functions are emitted in spawn order.
    async_fns: Map[str, int]
    async_wrappers: List[str]
    gather_wrappers: List[str]

    # Map helpers emitted after user functions: one find/rehash/put/remove set per map type.
    map_helpers: List[str]
    map_hash_kinds: List[str]

    # optimization / debug modes (passed by the CLI via !rgc.options metadata to the backend shim)
    opt_level: int
    debug_info: int
    source_path: str

    # debug-info state: current source location / current function DISubprogram / numbered metadata
    cur_line: int
    cur_col: int
    cur_sp_md: str
    md_next: int
    md_defs: List[str]
    md_cache: Map[str, str]        # "fn:line:col" -> DILocation id
    di_type_cache: Map[str, str]   # kind|custom -> DIType id
    di_file_md: str
    di_cu_md: str

    # emitted declarations
    emitted_types: Map[str, int]
    emitted_externs: Map[str, int]
    string_map: Map[str, str]
    string_list: List[str]
    string_lines: List[str]
    type_lines: List[str]
    body_start: int
    alloca_lines: List[str]
    in_fn: int
    fn_entry_idx: int
}

public def make_irgen(s: @var Sema) -> IRGen {
    g = IRGen()
    g.lines = List[str]()
    g.reg = 0
    g.label = 0
    g.cur_fn = ""
    g.cur_module = ""
    g.fn_ret_llvm = "void"
    g.fn_ret_kind = "None"
    g.fn_ret_custom = ""
    g.var_alloca = Map[str, str]()
    g.var_kind = Map[str, str]()
    g.var_type_name = Map[str, str]()
    g.var_is_ptr = Map[str, int]()
    g.loop_continue = List[str]()
    g.loop_exit = List[str]()
    g.class_order = s.class_order
    g.class_fields = s.class_fields
    g.class_field_types = s.class_field_types
    g.class_methods = s.class_methods
    g.fn_order = s.fn_order
    g.fn_ret_llvm_map = s.fn_ret_llvm
    g.fn_ret_kinds = s.fn_ret_kinds
    g.fn_ret_customs = s.fn_ret_customs
    g.fn_params_llvm = s.fn_params_llvm
    g.fn_param_kinds = s.fn_param_kinds
    g.fn_param_customs = s.fn_param_customs
    g.fn_is_extern = s.fn_is_extern
    g.enum_order = s.enum_order
    g.enum_variants = s.enum_variants
    g.enum_payloads = s.enum_payloads
    g.enum_variant_enum = s.enum_variant_enum
    g.enum_variant_idx = s.enum_variant_idx
    g.enum_field_kinds = s.enum_field_kinds
    g.enum_field_names = s.enum_field_names
    g.extra_stmts = s.extra_stmts
    g.generic_fn_names = s.generic_fn_names
    g.qualified_calls = s.qualified_calls
    g.call_syms = s.call_syms
    g.module_types = s.module_types
    g.from_imports = s.from_imports
    g.type_owners = s.type_owners
    g.glob_imports = s.glob_imports
    g.type_reexports = s.type_reexports
    g.async_fns = s.async_fns
    g.async_wrappers = List[str]()
    g.gather_wrappers = List[str]()
    g.map_helpers = List[str]()
    g.map_hash_kinds = List[str]()
    g.opt_level = 2
    g.debug_info = 0
    g.source_path = ""
    g.cur_line = 0
    g.cur_col = 0
    g.cur_sp_md = ""
    g.md_next = 0
    g.md_defs = List[str]()
    g.md_cache = Map[str, str]()
    g.di_type_cache = Map[str, str]()
    g.di_file_md = ""
    g.di_cu_md = ""
    g.emitted_types = Map[str, int]()
    g.emitted_externs = Map[str, int]()
    g.string_map = Map[str, str]()
    g.string_list = List[str]()
    g.string_lines = List[str]()
    g.type_lines = List[str]()
    g.body_start = 0
    g.alloca_lines = List[str]()
    g.in_fn = 0
    g.fn_entry_idx = 0
    return g
}

# ---------------------------------------------------------------------------
# basic helpers
# ---------------------------------------------------------------------------

public def irg_new_reg(g: @var IRGen) -> str {
    # Name temporaries: LLVM anonymous numeric registers must strictly increase in text order,
    # but expression codegen often allocates the result before generating operands, so named values are used.
    r = "%t" + to_string(g.reg)
    g.reg = g.reg + 1
    return r
}

public def irg_new_label(g: @var IRGen, base: str) -> str {
    l = base + "." + to_string(g.label)
    g.label = g.label + 1
    return l
}

public def irg_add(g: @var IRGen, line: str) {
    # Hoist all in-function allocas to the entry to dominate every use point.
    if g.in_fn == 1 and line.contains(" = alloca ") {
        g.alloca_lines.push(line + irg_dbg_suffix(g))
        return
    }
    # In debug mode, attach !dbg to in-body instructions (skipping labels / define / declare / function ends).
    if g.in_fn == 1 and line.len() > 0 and not line.endswith(":") and
       not str_eq(line, "}") and
       not line.startswith("declare ") and not line.startswith("define ") {
        line = line + irg_dbg_suffix(g)
    }
    g.lines.push(line)
}

public def irg_insert_lines(g: @var IRGen, idx: int, lines: List[str]) {
    newl = List[str]()
    i = 0
    while i < idx {
        newl.push(g.lines.get(i))
        i = i + 1
    }
    i = 0
    while i < lines.len() {
        newl.push(lines.get(i))
        i = i + 1
    }
    i = idx
    while i < g.lines.len() {
        newl.push(g.lines.get(i))
        i = i + 1
    }
    g.lines = newl
}

# ---------------------------------------------------------------------------
# Debug info (-g) and backend option metadata (!rgc.options)
# ---------------------------------------------------------------------------

# Text quote escaping for metadata string fields.
public def irg_md_quote(s: str) -> str {
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == "\"".char_at(0) {
            out = out + "\\\""
        } elif c == "\\".char_at(0) {
            out = out + "\\\\"
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return "\"" + out + "\""
}

# Allocate the next numbered metadata id (e.g. "!12").
public def irg_md_alloc(g: @var IRGen) -> str {
    id = "!" + to_string(g.md_next)
    g.md_next = g.md_next + 1
    return id
}

# kind/custom -> DIType metadata id. int/float/bool/str are modeled as basic types,
# everything else (classes / enums / borrows etc.) uses null (the debugger shows an opaque type).
public def irg_di_type(g: @var IRGen, kind: str, custom: str) -> str {
    key = kind + "|" + custom
    if g.di_type_cache.contains(key) {
        return g.di_type_cache.get(key)
    }
    id = "null"
    if str_eq(kind, "int") {
        id = irg_md_alloc(g)
        g.md_defs.push(id + " = !DIBasicType(name: \"int\", size: 64, encoding: DW_ATE_signed)")
    } elif str_eq(kind, "float") {
        id = irg_md_alloc(g)
        g.md_defs.push(id + " = !DIBasicType(name: \"double\", size: 64, encoding: DW_ATE_float)")
    } elif str_eq(kind, "bool") {
        id = irg_md_alloc(g)
        g.md_defs.push(id + " = !DIBasicType(name: \"bool\", size: 8, encoding: DW_ATE_boolean)")
    } elif str_eq(kind, "str") {
        base = irg_md_alloc(g)
        g.md_defs.push(base + " = !DIBasicType(name: \"char\", size: 8, encoding: DW_ATE_UTF)")
        id = irg_md_alloc(g)
        g.md_defs.push(id + " = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: " + base + ")")
    } elif str_eq(kind, "custom") and custom.len() > 0 {
        # classes / enums / List / Map etc.: opaque structs. Variable paths cannot use a null type,
        # otherwise LLVM's DWARF generation segfaults.
        id = irg_md_alloc(g)
        g.md_defs.push(id + " = !DICompositeType(tag: DW_TAG_structure_type, name: " +
                       irg_md_quote(custom) + ", scope: " + g.di_file_md +
                       ", file: " + g.di_file_md +
                       ", flags: DIFlagFwdDecl, identifier: " + irg_md_quote(custom) + ")")
    }
    g.di_type_cache.put(key, id)
    return id
}

# The !dbg suffix for the current source location (with DILocation definitions, deduplicated by function:line:col).
public def irg_dbg_suffix(g: @var IRGen) -> str {
    if g.debug_info == 0 or str_eq(g.cur_sp_md, "") or g.cur_line <= 0 {
        return ""
    }
    key = g.cur_fn + ":" + to_string(g.cur_line) + ":" + to_string(g.cur_col)
    if g.md_cache.contains(key) {
        return ", !dbg " + g.md_cache.get(key)
    }
    loc = irg_md_alloc(g)
    g.md_defs.push(loc + " = !DILocation(line: " + to_string(g.cur_line) +
                   ", column: " + to_string(g.cur_col) + ", scope: " + g.cur_sp_md + ")")
    g.md_cache.put(key, loc)
    return ", !dbg " + loc
}

# Variable debug info: DILocalVariable + llvm.dbg.declare (associates the variable name with its stack slot).
public def irg_dbg_declare(g: @var IRGen, name: str, alloca: str, kind: str,
                    custom: str, line: int) {
    if g.debug_info == 0 or str_eq(g.cur_sp_md, "") or g.di_file_md.len() == 0 {
        return
    }
    dv = irg_md_alloc(g)
    ty = irg_di_type(g, kind, custom)
    if str_eq(ty, "null") {
        ty = irg_di_type(g, "int", "")
    }
    g.md_defs.push(dv + " = !DILocalVariable(name: " + irg_md_quote(name) +
                   ", scope: " + g.cur_sp_md + ", file: " + g.di_file_md +
                   ", line: " + to_string(line) + ", type: " + ty + ")")
    irg_add(g, "call void @llvm.dbg.declare(metadata ptr " + alloca +
                ", metadata " + dv + ", metadata !DIExpression())")
}

# Create a distinct DISubprogram for a function (with DISubroutineType) and return its id.
public def irg_md_subprogram(g: @var IRGen, fn_name: str, f: @Stmt) -> str {
    sp = irg_md_alloc(g)
    ft = irg_md_alloc(g)
    tys = irg_md_alloc(g)
    ret = irg_di_type(g, g.fn_ret_kind, g.fn_ret_custom)
    tylist = "null"
    if not str_eq(ret, "null") {
        tylist = ret
    }
    if g.fn_param_kinds.contains(fn_name) and g.fn_param_customs.contains(fn_name) and
       g.fn_param_kinds.get(fn_name).len() > 0 {
        kinds = g.fn_param_kinds.get(fn_name).split(",")
        customs = g.fn_param_customs.get(fn_name).split(",")
        pi = 0
        while pi < kinds.len() {
            pc = ""
            if pi < customs.len() {
                pc = customs.get(pi)
            }
            pt = irg_di_type(g, kinds.get(pi), pc)
            if not str_eq(pt, "null") {
                tylist = tylist + ", " + pt
            }
            pi = pi + 1
        }
    }
    g.md_defs.push(tys + " = !{" + tylist + "}")
    g.md_defs.push(ft + " = !DISubroutineType(types: " + tys + ")")
    g.md_defs.push(sp + " = distinct !DISubprogram(name: " + irg_md_quote(fn_name) +
                   ", linkageName: " + irg_md_quote(fn_name) +
                   ", scope: " + g.di_file_md + ", file: " + g.di_file_md +
                   ", line: " + to_string(f.line) + ", type: " + ft +
                   ", spFlags: DISPFlagDefinition, unit: " + g.di_cu_md + ")")
    return sp
}

# Whether the current block has already been terminated by ret/br.
public def irg_is_terminated(g: @var IRGen) -> bool {
    if g.lines.len() == 0 {
        return False
    }
    last = g.lines.get(g.lines.len() - 1)
    return last.startswith("ret ") or last.startswith("br ") or
           str_eq(last, "unreachable")
}

# Zero-value literal for a type.
public def irg_zero_value(ty: str) -> str {
    if str_eq(ty, "ptr") { return "null" }
    if str_eq(ty, "double") { return "0.0" }
    if str_eq(ty, "i1") { return "false" }
    if ty.startswith("%") { return "zeroinitializer" }
    return "0"
}

# Type size (used for List growth; over-allocation keeps it safe).
public def llvm_type_size(g: @var IRGen, ty: str) -> int {
    if str_eq(ty, "i64") or str_eq(ty, "double") or str_eq(ty, "ptr") {
        return 8
    }
    if str_eq(ty, "i1") {
        return 8
    }
    if ty.startswith("%") {
        return struct_type_size(g, ty.slice(1, ty.len()))
    }
    return 8
}

public def struct_type_size(g: @var IRGen, name: str) -> int {
    # built-in containers.
    if name.startswith("List$") {
        return 24
    }
    if name.startswith("Map$") {
        return 80
    }
    if name.startswith("Maybe$") or name.startswith("Result$") {
        return 16
    }
    # classes: the sum of field sizes.
    if g.class_field_types.contains(name) {
        fts = g.class_field_types.get(name).split(",")
        total = 0
        i = 0
        while i < fts.len() {
            ft = fts.get(i)
            if ft.len() > 0 {
                total = total + llvm_type_size(g, ft)
            }
            i = i + 1
        }
        return total
    }
    # enums: disc + payload.
    if g.enum_payloads.contains(name) {
        return 8 + g.enum_payloads.get(name) * 8
    }
    return 8
}

# Escape a string constant into LLVM IR text.
public def llvm_escape(s: str) -> str {
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == "\"".char_at(0) {
            out = out + "\\22"
        } elif c == "\\".char_at(0) {
            out = out + "\\5C"
        } elif c >= 32 and c < 127 {
            out = out + s.slice(i, i + 1)
        } else {
            out = out + "\\" + hex2(c)
        }
        i = i + 1
    }
    return out
}

public def hex2(c: int) -> str {
    hi = c // 16
    lo = c % 16
    return hex_digit(hi) + hex_digit(lo)
}

public def hex_digit(d: int) -> str {
    if d < 10 {
        return to_string(d)
    }
    if d == 10 { return "A" }
    if d == 11 { return "B" }
    if d == 12 { return "C" }
    if d == 13 { return "D" }
    if d == 14 { return "E" }
    return "F"
}

# Get/create a string global constant.
public def irg_string(g: @var IRGen, s: str) -> str {
    if g.string_map.contains(s) {
        return g.string_map.get(s)
    }
    name = "@.str." + to_string(g.string_list.len())
    g.string_list.push(s)
    g.string_map.put(s, name)
    return name
}

public def irg_emit_string_const(g: @var IRGen, s: str) -> str {
    name = irg_string(g, s)
    # already emitted: skip.
    if g.emitted_externs.contains(name) {
        return name
    }
    n = s.len() + 1
    g.emitted_externs.put(name, 1)
    g.string_lines.push(name + " = private unnamed_addr constant [" + to_string(n) +
                        " x i8] c\"" + llvm_escape(s) + "\\00\"")
    return name
}

# Strip whitespace as the extern dedup key: built-in declarations and user extern defs may
# differ in comma spacing, but LLVM treats duplicate declarations as errors.
def irg_extern_key(decl: str) -> str {
    out = ""
    i = 0
    while i < decl.len() {
        c = decl.char_at(i)
        if c != 32 {
            out = out + decl.slice(i, i + 1)
        }
        i = i + 1
    }
    return out
}

# Emit an extern declaration (idempotent).
public def irg_extern(g: @var IRGen, decl: str) {
    key = irg_extern_key(decl)
    if g.emitted_externs.contains(key) {
        return
    }
    g.emitted_externs.put(key, 1)
    irg_add(g, "declare " + decl)
}

# ---------------------------------------------------------------------------
# type declarations
# ---------------------------------------------------------------------------

# Ensure a custom type is declared (List/Map/class/enum/Maybe/Result).
public def irg_ensure_type(g: @var IRGen, name: str) {
    if name.len() == 0 {
        return
    }
    if g.emitted_types.contains(name) {
        return
    }
    g.emitted_types.put(name, 1)

    if name.startswith("List$") {
        g.type_lines.push("%" + name + " = type { ptr, i64, i64 }")
        return
    }
    if name.startswith("Map$") {
        rest = name.slice(4, name.len())
        d = str_find(rest, "$")
        k = rest.slice(0, d)
        v = rest.slice(d + 1, rest.len())
        irg_ensure_type(g, "List$" + k)
        irg_ensure_type(g, "List$" + v)
        g.type_lines.push("%" + name + " = type { %List$" + k + ", %List$" + v +
                          ", ptr, i64, i64, i64 }")
        return
    }
    if name.startswith("Maybe$") or name.startswith("Result$") {
        irg_ensure_enum_layout(g, name)
        g.type_lines.push("%" + name + " = type { i8, [1 x i64] }")
        return
    }
    if g.class_fields.contains(name) {
        # declare field types first.
        fts = g.class_field_types.get(name).split(",")
        i = 0
        while i < fts.len() {
            ft = fts.get(i)
            if ft.startswith("%") {
                irg_ensure_type(g, ft.slice(1, ft.len()))
            }
            i = i + 1
        }
        body = g.class_field_types.get(name)
        g.type_lines.push("%" + name + " = type { " + body + " }")
        return
    }
    if g.enum_payloads.contains(name) {
        n = g.enum_payloads.get(name)
        g.type_lines.push("%" + name + " = type { i8, [" + to_string(n) + " x i64] }")
        return
    }
}

# Ensure Maybe$/Result$ layouts are registered (variant/payload kinds).
public def irg_ensure_enum_layout(g: @var IRGen, name: str) {
    if g.enum_variants.contains(name) {
        return
    }
    if name.startswith("Maybe$") {
        g.enum_order.push(name)
        g.enum_variants.put(name, "Some,Nothing")
        g.enum_payloads.put(name, 1)
        g.enum_variant_enum.put("Some", name)
        g.enum_variant_idx.put("Some", 0)
        g.enum_variant_enum.put("Nothing", name)
        g.enum_variant_idx.put("Nothing", 1)
        payload = name.slice(6, name.len())
        g.enum_field_kinds.put(name, payload + "|")
        g.enum_field_names.put(name, "v|")
    } elif name.startswith("Result$") {
        g.enum_order.push(name)
        g.enum_variants.put(name, "Ok,Err")
        g.enum_payloads.put(name, 1)
        g.enum_variant_enum.put("Ok", name)
        g.enum_variant_idx.put("Ok", 0)
        g.enum_variant_enum.put("Err", name)
        g.enum_variant_idx.put("Err", 1)
        rest = name.slice(7, name.len())
        d = str_find(rest, "$")
        ok_kind = rest.slice(0, d)
        err_kind = rest.slice(d + 1, rest.len())
        g.enum_field_kinds.put(name, ok_kind + "|" + err_kind)
        g.enum_field_names.put(name, "v|e")
    }
}

# mangled name -> LLVM type.
public def irg_llvm_type(g: @var IRGen, kind: str, custom: str) -> str {
    if str_eq(kind, "int") { return "i64" }
    if str_eq(kind, "float") { return "double" }
    if str_eq(kind, "bool") { return "i1" }
    if str_eq(kind, "str") { return "ptr" }
    if str_eq(kind, "None") { return "i64" }
    if str_eq(kind, "custom") {
        return "%" + custom
    }
    return "i64"
}

# mangled element name -> LLVM type.
public def irg_elem_llvm_type(g: @var IRGen, elem: str) -> str {
    if str_eq(elem, "int") { return "i64" }
    if str_eq(elem, "float") { return "double" }
    if str_eq(elem, "bool") { return "i1" }
    if str_eq(elem, "str") { return "ptr" }
    if str_eq(elem, "None") { return "i64" }
    if elem.startswith("List$") {
        return "%" + elem
    }
    if elem.startswith("Map$") {
        return "%" + elem
    }
    return "%" + elem
}

# mangled element name -> kind name.
public def irg_elem_kind(elem: str) -> str {
    if str_eq(elem, "int") { return "int" }
    if str_eq(elem, "float") { return "float" }
    if str_eq(elem, "bool") { return "bool" }
    if str_eq(elem, "str") { return "str" }
    if str_eq(elem, "None") { return "None" }
    return "custom"
}

# ---------------------------------------------------------------------------
# Expression type inference (for code generation)
# ---------------------------------------------------------------------------

# Ok payload mangled name of a Result (split at the first $, matching enum layout conventions).
public def irg_result_ok_elem(custom: str) -> str {
    if custom.startswith("Result$") {
        rest = custom.slice(7, custom.len())
        d = str_find(rest, "$")
        if d >= 0 {
            return rest.slice(0, d)
        }
    }
    return ""
}

public def irg_is_math_builtin(name: str) -> bool {
    return str_eq(name, "abs") or str_eq(name, "min") or str_eq(name, "max") or
           str_eq(name, "sqrt") or str_eq(name, "pow") or
           str_eq(name, "floor") or str_eq(name, "ceil")
}

# math call result kinds: abs follows the argument; min/max promote when any float is present; the rest return float.
public def irg_math_call_kind(g: @var IRGen, name: str, e: @Expr) -> str {
    if str_eq(name, "sqrt") or str_eq(name, "pow") or
       str_eq(name, "floor") or str_eq(name, "ceil") {
        return "float"
    }
    k0 = "int"
    if e.args.len() > 0 {
        a0 = e.args.get(0)
        k0 = irg_expr_kind(g, a0)
    }
    if str_eq(name, "abs") {
        return k0
    }
    k1 = "int"
    if e.args.len() > 1 {
        a1 = e.args.get(1)
        k1 = irg_expr_kind(g, a1)
    }
    if str_eq(k0, "float") or str_eq(k1, "float") {
        return "float"
    }
    return "int"
}

public def irg_math_to_f64(g: @var IRGen, kind: str, v: str) -> str {
    if str_eq(kind, "float") {
        return v
    }
    f = irg_new_reg(g)
    irg_add(g, f + " = sitofp i64 " + v + " to double")
    return f
}

public def irg_expr_kind(g: @var IRGen, e: Expr) -> str {
    if e.kind == ExprIntLit() or e.kind == ExprNoneLit() {
        return "int"
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
        if g.var_kind.contains(e.name) {
            return g.var_kind.get(e.name)
        }
        return "error"
    }
    if e.kind == ExprUnary() {
        if str_eq(e.op, "not") {
            return "bool"
        }
        return irg_expr_kind(g, e.operand.get(0))
    }
    if e.kind == ExprBorrow() {
        return irg_expr_kind(g, e.operand.get(0))
    }
    if e.kind == ExprTry() {
        return irg_elem_kind(irg_result_ok_elem(
            irg_expr_type_name(g, e.operand.get(0))))
    }
    if e.kind == ExprAwait() {
        op = e.operand.get(0)
        t = irg_expr_type_name_ref(g, @op)
        return irg_elem_kind(irg_task_payload_of(t))
    }
    if e.kind == ExprBinary() {
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
        lk = irg_expr_kind(g, e.lhs.get(0))
        rk = irg_expr_kind(g, e.rhs.get(0))
        if str_eq(e.op, "+") and (str_eq(lk, "str") or str_eq(rk, "str")) {
            return "str"
        }
        if str_eq(lk, "float") or str_eq(rk, "float") {
            return "float"
        }
        return lk
    }
    if e.kind == ExprCall() {
        if e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            qkey = irg_call_key(@var g, @e)
            if g.qualified_calls.contains(qkey) {
                qn = g.qualified_calls.get(qkey)
                if qn.startswith("math.") {
                    return irg_math_call_kind(g, qn.slice(5, qn.len()), @e)
                }
                if str_eq(qn, "asyncio.run") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        t = irg_expr_type_name_ref(g, @a0)
                        return irg_elem_kind(irg_task_payload_of(t))
                    }
                    return "error"
                }
                if str_eq(qn, "asyncio.gather") {
                    return "custom"
                }
                if str_eq(qn, "asyncio.wait_any") {
                    return "int"
                }
                if str_eq(qn, "asyncio.cancelled") {
                    return "bool"
                }
                if g.async_fns.contains(qn) {
                    return "custom"
                }
                if g.fn_ret_kinds.contains(qn) {
                    return g.fn_ret_kinds.get(qn)
                }
                return "error"
            }
        }
        if e.type_args.len() > 0 {
            return "custom"
        }
        if g.generic_fn_names.contains(e.name) {
            inst = irg_call_target(g, @e)
            if g.async_fns.contains(inst) {
                return "custom"
            }
            if g.fn_ret_kinds.contains(inst) {
                return g.fn_ret_kinds.get(inst)
            }
        }
        if g.class_fields.contains(irg_resolve_type_key(g, e.name)) or
           g.enum_variant_enum.contains(e.name) {
            return "custom"
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            return "custom"
        }
        if e.object.len() > 0 {
            obj_kind = irg_expr_kind(g, e.object.get(0))
            obj_custom = irg_expr_type_name(g, e.object.get(0))
            return irg_method_kind(g, obj_kind, obj_custom, e.name)
        }
        ct = irg_call_target(g, @e)
        if g.async_fns.contains(ct) {
            return "custom"
        }
        if g.fn_ret_kinds.contains(ct) {
            return irg_fn_ret_kind(g, ct)
        }
        if irg_is_math_builtin(e.name) {
            return irg_math_call_kind(g, e.name, @e)
        }
        return irg_fn_ret_kind(g, e.name)
    }
    if e.kind == ExprIf() {
        if e.then_block.len() > 0 {
            return irg_expr_kind(g, e.then_block.get(0))
        }
        return "None"
    }
    if e.kind == ExprBlock() {
        if e.result.len() > 0 {
            return irg_expr_kind(g, e.result.get(0))
        }
        return "None"
    }
    if e.kind == ExprAssign() {
        return irg_expr_kind(g, e.value.get(0))
    }
    if e.kind == ExprMember() {
        return irg_member_kind(g, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        if e.arms.len() > 0 {
            return irg_expr_kind(g, e.arms.get(0).body)
        }
        return "None"
    }
    return "error"
}

# Borrowing variant: does not move e (for cases where the type is needed before codegen).
public def irg_expr_kind_ref(g: @var IRGen, e: @Expr) -> str {
    if e.kind == ExprIntLit() or e.kind == ExprNoneLit() {
        return "int"
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
        if g.var_kind.contains(e.name) {
            return g.var_kind.get(e.name)
        }
        return "error"
    }
    if e.kind == ExprUnary() {
        if str_eq(e.op, "not") {
            return "bool"
        }
        return irg_expr_kind(g, e.operand.get(0))
    }
    if e.kind == ExprBorrow() {
        return irg_expr_kind(g, e.operand.get(0))
    }
    if e.kind == ExprTry() {
        return irg_elem_kind(irg_result_ok_elem(
            irg_expr_type_name(g, e.operand.get(0))))
    }
    if e.kind == ExprAwait() {
        op = e.operand.get(0)
        t = irg_expr_type_name_ref(g, @op)
        return irg_elem_kind(irg_task_payload_of(t))
    }
    if e.kind == ExprBinary() {
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
        lk = irg_expr_kind(g, e.lhs.get(0))
        rk = irg_expr_kind(g, e.rhs.get(0))
        if str_eq(e.op, "+") and (str_eq(lk, "str") or str_eq(rk, "str")) {
            return "str"
        }
        if str_eq(lk, "float") or str_eq(rk, "float") {
            return "float"
        }
        return lk
    }
    if e.kind == ExprCall() {
        if e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            qkey = irg_call_key(@var g, @e)
            if g.qualified_calls.contains(qkey) {
                qn = g.qualified_calls.get(qkey)
                if qn.startswith("math.") {
                    return irg_math_call_kind(g, qn.slice(5, qn.len()), e)
                }
                if str_eq(qn, "asyncio.run") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        t = irg_expr_type_name_ref(g, @a0)
                        return irg_elem_kind(irg_task_payload_of(t))
                    }
                    return "error"
                }
                if str_eq(qn, "asyncio.gather") {
                    return "custom"
                }
                if str_eq(qn, "asyncio.wait_any") {
                    return "int"
                }
                if str_eq(qn, "asyncio.cancelled") {
                    return "bool"
                }
                if g.async_fns.contains(qn) {
                    return "custom"
                }
                if g.fn_ret_kinds.contains(qn) {
                    return g.fn_ret_kinds.get(qn)
                }
                return "error"
            }
        }
        if e.type_args.len() > 0 {
            return "custom"
        }
        if g.generic_fn_names.contains(e.name) {
            inst = irg_call_target(g, @e)
            if g.async_fns.contains(inst) {
                return "custom"
            }
            if g.fn_ret_kinds.contains(inst) {
                return g.fn_ret_kinds.get(inst)
            }
        }
        if g.class_fields.contains(irg_resolve_type_key(g, e.name)) or
           g.enum_variant_enum.contains(e.name) {
            return "custom"
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            return "custom"
        }
        if e.object.len() > 0 {
            obj_kind = irg_expr_kind(g, e.object.get(0))
            obj_custom = irg_expr_type_name(g, e.object.get(0))
            return irg_method_kind(g, obj_kind, obj_custom, e.name)
        }
        ct = irg_call_target(g, @e)
        if g.async_fns.contains(ct) {
            return "custom"
        }
        if g.fn_ret_kinds.contains(ct) {
            return irg_fn_ret_kind(g, ct)
        }
        if irg_is_math_builtin(e.name) {
            return irg_math_call_kind(g, e.name, e)
        }
        return irg_fn_ret_kind(g, e.name)
    }
    if e.kind == ExprIf() {
        if e.then_block.len() > 0 {
            return irg_expr_kind(g, e.then_block.get(0))
        }
        return "None"
    }
    if e.kind == ExprBlock() {
        if e.result.len() > 0 {
            return irg_expr_kind(g, e.result.get(0))
        }
        return "None"
    }
    if e.kind == ExprAssign() {
        return irg_expr_kind(g, e.value.get(0))
    }
    if e.kind == ExprMember() {
        return irg_member_kind(g, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        if e.arms.len() > 0 {
            return irg_expr_kind(g, e.arms.get(0).body)
        }
        return "None"
    }
    return "error"
}

# Top-level function symbols: module functions (including public) are physically renamed to module$name,
# matching Sema registration keys; same-named symbols therefore never collide.
# extern defs keep bare symbol names (visible to the C linker). Generic instance names already carry a prefix, so startswith prevents duplicates.
public def irg_fn_sym(st: @Stmt) -> str {
    sym = st.name
    if st.module_name.len() > 0 and not st.is_extern {
        prefix = st.module_name + "$"
        if not sym.startswith(prefix) {
            sym = prefix + sym
        }
    }
    return sym
}

# ---------- module namespace resolution (same chain as Sema; the IR side's data is shared with Sema) ----------

# Whether the type is registered.
public def irg_type_registered(g: @var IRGen, key: str) -> bool {
    return g.class_fields.contains(key) or g.enum_field_kinds.contains(key)
}

# from-import lookup.
public def irg_from_lookup(g: @var IRGen, name: str) -> str {
    if g.from_imports.len() == 0 {
        return ""
    }
    key = g.cur_module + "$" + name
    if g.from_imports.contains(key) {
        return g.from_imports.get(key)
    }
    return ""
}

# Type resolution: source bare name -> registration key; on failure returns the original name (Sema already validated, so ambiguity never reaches here).
public def irg_resolve_type_key(g: @var IRGen, name: str) -> str {
    if name.len() == 0 {
        return name
    }
    if g.cur_module.len() > 0 {
        key = g.cur_module + "$" + name
        if g.module_types.contains(key) {
            return key
        }
    }
    fk = irg_from_lookup(g, name)
    if fk.len() > 0 {
        parts = fk.split(".")
        if parts.len() == 2 {
            tkey = parts.get(0) + "$" + parts.get(1)
            depth = 0
            while not irg_type_registered(g, tkey) and g.type_reexports.contains(tkey) and depth < 8 {
                tkey = g.type_reexports.get(tkey)
                depth = depth + 1
            }
            if irg_type_registered(g, tkey) {
                return tkey
            }
        }
    }
    if irg_type_registered(g, name) {
        return name
    }
    # glob import: unique candidate (Sema already reported ambiguities; they never reach here).
    if g.glob_imports.len() > 0 {
        prefix = g.cur_module + "$"
        found = ""
        count = 0
        gi = 0
        while gi < g.glob_imports.len() {
            gkey = g.glob_imports.get(gi)
            if gkey.startswith(prefix) {
                gmod = gkey.slice(prefix.len(), gkey.len())
                tcand = gmod + "$" + name
                if g.module_types.contains(tcand) {
                    found = tcand
                    count = count + 1
                }
            }
            gi = gi + 1
        }
        if count == 1 {
            return found
        }
    }
    if g.type_owners.contains(name) {
        owner = g.type_owners.get(name)
        if not str_eq(owner, "<multi>") {
            tkey2 = owner + "$" + name
            if irg_type_registered(g, tkey2) {
                return tkey2
            }
        }
    }
    return name
}

# Call-site physical symbol: prefer Sema's recorded resolution; otherwise fall back to local derivation.
# Call-site key: isomorphic to sema_call_key on the Sema side (module prefix + line:col).
public def irg_call_key(g: @var IRGen, e: @Expr) -> str {
    return g.cur_module + "$" + expr_call_key(e)
}

public def irg_call_target(g: @var IRGen, e: @Expr) -> str {
    key = irg_call_key(@var g, @e)
    if g.call_syms.contains(key) {
        return g.call_syms.get(key)
    }
    if g.generic_fn_names.contains(e.name) {
        return irg_generic_fn_name(g, e)
    }
    return irg_module_fn_name(g, e.name)
}

public def irg_module_fn_name(g: @var IRGen, name: str) -> str {
    if g.cur_module.len() > 0 {
        key = g.cur_module + "$" + name
        if g.fn_ret_kinds.contains(key) {
            return key
        }
    }
    return name
}

public def irg_fn_ret_kind(g: @var IRGen, name: str) -> str {
    key0 = irg_module_fn_name(g, name)
    if g.fn_ret_kinds.contains(key0) {
        return g.fn_ret_kinds.get(key0)
    }
    if str_eq(name, "print") { return "None" }
    if str_eq(name, "to_string") { return "str" }
    if str_eq(name, "chr") { return "str" }
    if str_eq(name, "format") { return "str" }
    if str_eq(name, "args") { return "custom" }
    if str_eq(name, "system") { return "int" }
    if str_eq(name, "read_file") { return "custom" }
    if str_eq(name, "write_file") { return "custom" }
    if str_eq(name, "append_file") { return "custom" }
    if str_eq(name, "remove_file") { return "custom" }
    if str_eq(name, "exists") { return "bool" }
    if str_eq(name, "range") { return "custom" }
    return "error"
}

public def irg_expr_type_name(g: @var IRGen, e: Expr) -> str {
    if e.kind == ExprVar() {
        if g.var_type_name.contains(e.name) {
            return g.var_type_name.get(e.name)
        }
        return ""
    }
    if e.kind == ExprCall() {
        if e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            qkey = irg_call_key(@var g, @e)
            if g.qualified_calls.contains(qkey) {
                qn = g.qualified_calls.get(qkey)
                if str_eq(qn, "asyncio.run") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        t = irg_expr_type_name_ref(g, @a0)
                        pay = irg_task_payload_of(t)
                        if str_eq(irg_elem_kind(pay), "custom") {
                            return pay
                        }
                    }
                    return ""
                }
                if str_eq(qn, "asyncio.gather") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        c = irg_expr_type_name_ref(g, @a0)
                        if c.startswith("List$Task$") {
                            p = irg_task_payload_of(c.slice(5, c.len()))
                            return "Task$List$" + p
                        }
                    }
                    return ""
                }
                if g.async_fns.contains(qn) {
                    return irg_task_type_of_fn(g, qn)
                }
                if g.fn_ret_customs.contains(qn) {
                    return g.fn_ret_customs.get(qn)
                }
                return ""
            }
        }
        if e.type_args.len() > 0 {
            if str_eq(e.name, "List") or str_eq(e.name, "Maybe") {
                return e.name + "$" + irg_te_mangled(g, e.type_args.get(0))
            }
            if str_eq(e.name, "Map") or str_eq(e.name, "Result") {
                return e.name + "$" + irg_te_mangled(g, e.type_args.get(0)) + "$" +
                       irg_te_mangled(g, e.type_args.get(1))
            }
            full = irg_resolve_type_key(g, e.name)
            ti = 0
            while ti < e.type_args.len() {
                full = full + "$" + irg_te_mangled(g, e.type_args.get(ti))
                ti = ti + 1
            }
            return full
        }
        if g.generic_fn_names.contains(e.name) {
            inst = irg_call_target(g, @e)
            if g.async_fns.contains(inst) {
                return irg_task_type_of_fn(g, inst)
            }
            if g.fn_ret_customs.contains(inst) {
                return g.fn_ret_customs.get(inst)
            }
            return ""
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            return mangled_of_type_apply(g, e.object.get(0))
        }
        if e.object.len() > 0 {
            obj_custom = irg_expr_type_name(g, e.object.get(0))
            return irg_method_custom(g, obj_custom, e.name)
        }
        if g.class_fields.contains(irg_resolve_type_key(g, e.name)) {
            return irg_resolve_type_key(g, e.name)
        }
        if g.enum_variant_enum.contains(e.name) {
            return g.enum_variant_enum.get(e.name)
        }
        if str_eq(e.name, "args") { return "List$str" }
        if str_eq(e.name, "read_file") { return "Result$str$str" }
        if str_eq(e.name, "write_file") { return "Result$None$str" }
        if str_eq(e.name, "append_file") { return "Result$None$str" }
        if str_eq(e.name, "remove_file") { return "Result$None$str" }
        if str_eq(e.name, "range") { return "List$int" }
        if str_eq(e.name, "to_string") { return "" }
        fn_key = irg_call_target(g, @e)
        if g.async_fns.contains(fn_key) {
            return irg_task_type_of_fn(g, fn_key)
        }
        if fn_key.len() > 0 and g.fn_ret_customs.contains(fn_key) {
            return g.fn_ret_customs.get(fn_key)
        }
        return ""
    }
    if e.kind == ExprAssign() {
        return irg_expr_type_name(g, e.value.get(0))
    }
    if e.kind == ExprBorrow() {
        return irg_expr_type_name(g, e.operand.get(0))
    }
    if e.kind == ExprTry() {
        ok = irg_result_ok_elem(irg_expr_type_name(g, e.operand.get(0)))
        if str_eq(irg_elem_kind(ok), "custom") {
            return ok
        }
        return ""
    }
    if e.kind == ExprAwait() {
        op = e.operand.get(0)
        t = irg_expr_type_name_ref(g, @op)
        pay = irg_task_payload_of(t)
        if str_eq(irg_elem_kind(pay), "custom") {
            return pay
        }
        return ""
    }
    if e.kind == ExprMember() {
        return irg_member_custom(g, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        return irg_expr_type_name(g, e.subject.get(0))
    }
    return ""
}

# Borrowing variant: does not move e (for cases needing to re-read the same node).
public def irg_expr_type_name_ref(g: @var IRGen, e: @Expr) -> str {
    if e.kind == ExprVar() {
        if g.var_type_name.contains(e.name) {
            return g.var_type_name.get(e.name)
        }
        return ""
    }
    if e.kind == ExprCall() {
        if e.object.len() == 1 and e.object.get(0).kind == ExprVar() {
            qkey = irg_call_key(@var g, @e)
            if g.qualified_calls.contains(qkey) {
                qn = g.qualified_calls.get(qkey)
                if str_eq(qn, "asyncio.run") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        t = irg_expr_type_name_ref(g, @a0)
                        pay = irg_task_payload_of(t)
                        if str_eq(irg_elem_kind(pay), "custom") {
                            return pay
                        }
                    }
                    return ""
                }
                if str_eq(qn, "asyncio.gather") {
                    if e.args.len() == 1 {
                        a0 = e.args.get(0)
                        c = irg_expr_type_name_ref(g, @a0)
                        if c.startswith("List$Task$") {
                            p = irg_task_payload_of(c.slice(5, c.len()))
                            return "Task$List$" + p
                        }
                    }
                    return ""
                }
                if g.async_fns.contains(qn) {
                    return irg_task_type_of_fn(g, qn)
                }
                if g.fn_ret_customs.contains(qn) {
                    return g.fn_ret_customs.get(qn)
                }
                return ""
            }
        }
        if e.type_args.len() > 0 {
            if str_eq(e.name, "List") or str_eq(e.name, "Maybe") {
                return e.name + "$" + irg_te_mangled(g, e.type_args.get(0))
            }
            if str_eq(e.name, "Map") or str_eq(e.name, "Result") {
                return e.name + "$" + irg_te_mangled(g, e.type_args.get(0)) + "$" +
                       irg_te_mangled(g, e.type_args.get(1))
            }
            full = irg_resolve_type_key(g, e.name)
            ti = 0
            while ti < e.type_args.len() {
                full = full + "$" + irg_te_mangled(g, e.type_args.get(ti))
                ti = ti + 1
            }
            return full
        }
        if g.generic_fn_names.contains(e.name) {
            inst = irg_call_target(g, @e)
            if g.async_fns.contains(inst) {
                return irg_task_type_of_fn(g, inst)
            }
            if g.fn_ret_customs.contains(inst) {
                return g.fn_ret_customs.get(inst)
            }
            return ""
        }
        if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
            return mangled_of_type_apply(g, e.object.get(0))
        }
        if e.object.len() > 0 {
            obj_custom = irg_expr_type_name(g, e.object.get(0))
            return irg_method_custom(g, obj_custom, e.name)
        }
        if g.class_fields.contains(irg_resolve_type_key(g, e.name)) {
            return irg_resolve_type_key(g, e.name)
        }
        if g.enum_variant_enum.contains(e.name) {
            return g.enum_variant_enum.get(e.name)
        }
        if str_eq(e.name, "args") { return "List$str" }
        if str_eq(e.name, "read_file") { return "Result$str$str" }
        if str_eq(e.name, "write_file") { return "Result$None$str" }
        if str_eq(e.name, "append_file") { return "Result$None$str" }
        if str_eq(e.name, "remove_file") { return "Result$None$str" }
        if str_eq(e.name, "range") { return "List$int" }
        if str_eq(e.name, "to_string") { return "" }
        fn_key = irg_call_target(g, @e)
        if g.async_fns.contains(fn_key) {
            return irg_task_type_of_fn(g, fn_key)
        }
        if fn_key.len() > 0 and g.fn_ret_customs.contains(fn_key) {
            return g.fn_ret_customs.get(fn_key)
        }
        return ""
    }
    if e.kind == ExprAssign() {
        return irg_expr_type_name(g, e.value.get(0))
    }
    if e.kind == ExprBorrow() {
        return irg_expr_type_name(g, e.operand.get(0))
    }
    if e.kind == ExprTry() {
        ok = irg_result_ok_elem(irg_expr_type_name(g, e.operand.get(0)))
        if str_eq(irg_elem_kind(ok), "custom") {
            return ok
        }
        return ""
    }
    if e.kind == ExprAwait() {
        op = e.operand.get(0)
        t = irg_expr_type_name_ref(g, @op)
        pay = irg_task_payload_of(t)
        if str_eq(irg_elem_kind(pay), "custom") {
            return pay
        }
        return ""
    }
    if e.kind == ExprMember() {
        return irg_member_custom(g, e.object.get(0), e.name)
    }
    if e.kind == ExprMatch() {
        return irg_expr_type_name(g, e.subject.get(0))
    }
    return ""
}

public def mangled_of_type_apply(g: @var IRGen, ta: Expr) -> str {
    name = irg_resolve_type_key(g, ta.ta_name)
    i = 0
    while i < ta.ta_args.len() {
        name = name + "$" + irg_te_mangled(g, ta.ta_args.get(i))
        i = i + 1
    }
    return name
}

# Variant indexes of built-in generic enums (avoids multiple Maybe$/Result$ instances sharing a global map and cross-talking).
public def irg_builtin_variant_idx(enum_name: str, variant: str) -> int {
    if enum_name.startswith("Maybe$") {
        if str_eq(variant, "Some") { return 0 }
        if str_eq(variant, "Nothing") { return 1 }
    }
    if enum_name.startswith("Result$") {
        if str_eq(variant, "Ok") { return 0 }
        if str_eq(variant, "Err") { return 1 }
    }
    return -1
}

# mangled name (with resolution): custom type names are resolved against the module namespace before concatenation.
public def irg_te_mangled(g: @var IRGen, te: TypeExpr) -> str {
    if str_eq(te.name, "List") and te.args.len() == 1 {
        return "List$" + irg_te_mangled(g, te.args.get(0))
    }
    if str_eq(te.name, "Map") and te.args.len() == 2 {
        return "Map$" + irg_te_mangled(g, te.args.get(0)) + "$" + irg_te_mangled(g, te.args.get(1))
    }
    if str_eq(te.name, "Maybe") and te.args.len() == 1 {
        return "Maybe$" + irg_te_mangled(g, te.args.get(0))
    }
    if str_eq(te.name, "Result") and te.args.len() == 2 {
        return "Result$" + irg_te_mangled(g, te.args.get(0)) + "$" + irg_te_mangled(g, te.args.get(1))
    }
    if str_eq(te.name, "Task") and te.args.len() == 1 {
        return "Task$" + irg_te_mangled(g, te.args.get(0))
    }
    if str_eq(te.name, "int") or str_eq(te.name, "float") or str_eq(te.name, "bool") or
       str_eq(te.name, "str") or str_eq(te.name, "None") or te.name.len() == 0 {
        return te.name
    }
    return irg_resolve_type_key(g, te.name)
}

# mangled name (no resolution; built-in types only).
public def te_to_mangled(te: TypeExpr) -> str {
    if str_eq(te.name, "List") and te.args.len() == 1 {
        return "List$" + te_to_mangled(te.args.get(0))
    }
    if str_eq(te.name, "Map") and te.args.len() == 2 {
        return "Map$" + te_to_mangled(te.args.get(0)) + "$" + te_to_mangled(te.args.get(1))
    }
    if str_eq(te.name, "Maybe") and te.args.len() == 1 {
        return "Maybe$" + te_to_mangled(te.args.get(0))
    }
    if str_eq(te.name, "Result") and te.args.len() == 2 {
        return "Result$" + te_to_mangled(te.args.get(0)) + "$" + te_to_mangled(te.args.get(1))
    }
    if str_eq(te.name, "Task") and te.args.len() == 1 {
        return "Task$" + te_to_mangled(te.args.get(0))
    }
    return te.name
}

# ---------------------------------------------------------------------------
# async / Task
# ---------------------------------------------------------------------------

public def irg_task_payload_of(task: str) -> str {
    if task.startswith("Task$") {
        return task.slice(5, task.len())
    }
    return ""
}

public def irg_task_type_of_fn(g: @var IRGen, fn: str) -> str {
    if not g.fn_ret_kinds.contains(fn) {
        return ""
    }
    kind = g.fn_ret_kinds.get(fn)
    if str_eq(kind, "custom") {
        return "Task$" + g.fn_ret_customs.get(fn)
    }
    return "Task$" + kind
}

public def irg_task_payload_llvm(g: @var IRGen, task: str) -> str {
    p = irg_task_payload_of(task)
    if str_eq(p, "int") { return "i64" }
    if str_eq(p, "float") { return "double" }
    if str_eq(p, "bool") { return "i1" }
    if str_eq(p, "str") { return "ptr" }
    if str_eq(p, "None") { return "i64" }
    if p.len() > 0 {
        irg_ensure_type(g, p)
        return "%" + p
    }
    return "i64"
}

# Thread result box: { i64 tid, i64 done, T payload, i64 cancel }.
# cancel is placed last so the existing done/payload indexes stay unchanged.
public def irg_ensure_task_box(g: @var IRGen, task: str) {
    p = irg_task_payload_of(task)
    name = "TaskBox$" + p
    if g.emitted_types.contains(name) {
        return
    }
    g.emitted_types.put(name, 1)
    pty = irg_task_payload_llvm(g, task)
    g.type_lines.push("%" + name + " = type { i64, i64, " + pty + ", i64 }")
}

# gather argument block: { ptr box, ptr tasks_data, i64 tasks_len }.
public def irg_ensure_gather_args(g: @var IRGen, p: str) {
    name = "GatherArgs$" + p
    if g.emitted_types.contains(name) {
        return
    }
    g.emitted_types.put(name, 1)
    g.type_lines.push("%" + name + " = type { ptr, ptr, i64 }")
}

# Thread argument block: { ptr box, args... }.
public def irg_ensure_task_args(g: @var IRGen, fn: str) {
    name = "TaskArgs$" + fn
    if g.emitted_types.contains(name) {
        return
    }
    g.emitted_types.put(name, 1)
    body = "ptr"
    params = g.fn_params_llvm.get(fn)
    if params.len() > 0 {
        body = body + ", " + params
    }
    g.type_lines.push("%" + name + " = type { " + body + " }")
}

# Built-in method return kinds.
public def irg_method_kind(g: @var IRGen, obj_kind: str, obj_custom: str, m: str) -> str {
    if str_eq(obj_kind, "str") {
        if str_eq(m, "len") or str_eq(m, "char_at") or
           str_eq(m, "find") or str_eq(m, "rfind") {
            return "int"
        }
        if str_eq(m, "contains") or str_eq(m, "startswith") or str_eq(m, "endswith") {
            return "bool"
        }
        if str_eq(m, "slice") or str_eq(m, "join") or str_eq(m, "trim") or
           str_eq(m, "trim_start") or str_eq(m, "trim_end") or
           str_eq(m, "replace") or str_eq(m, "repeat") {
            return "str"
        }
        if str_eq(m, "to_int") or str_eq(m, "to_float") or
           str_eq(m, "split") or str_eq(m, "lines") {
            return "custom"
        }
        return "None"
    }
    if obj_custom.startswith("List$") {
        if str_eq(m, "len") or str_eq(m, "index_of") { return "int" }
        if str_eq(m, "contains") or str_eq(m, "remove") { return "bool" }
        if str_eq(m, "push") or str_eq(m, "set") or str_eq(m, "clear") or
           str_eq(m, "insert") or str_eq(m, "reverse") { return "None" }
        if str_eq(m, "pop") or str_eq(m, "get") or str_eq(m, "remove_at") {
            return irg_elem_kind(obj_custom.slice(5, obj_custom.len()))
        }
        return "None"
    }
    if obj_custom.startswith("Map$") {
        if str_eq(m, "len") { return "int" }
        if str_eq(m, "contains") or str_eq(m, "remove") { return "bool" }
        if str_eq(m, "get") {
            rest = obj_custom.slice(4, obj_custom.len())
            d = str_find(rest, "$")
            return irg_elem_kind(rest.slice(d + 1, rest.len()))
        }
        if str_eq(m, "put") { return "None" }
        if str_eq(m, "keys") or str_eq(m, "values") { return "custom" }
        return "None"
    }
    if obj_custom.startswith("Task$") {
        if str_eq(m, "done") { return "bool" }
        if str_eq(m, "wait") { return "bool" }
        if str_eq(m, "cancel") or str_eq(m, "cancelled") { return "bool" }
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
            return irg_elem_kind(first)
        }
        return "None"
    }
    # user class methods.
    fn = obj_custom + "$" + m
    if g.fn_ret_kinds.contains(fn) {
        return g.fn_ret_kinds.get(fn)
    }
    return "None"
}

public def irg_method_custom(g: @var IRGen, obj_custom: str, m: str) -> str {
    if str_eq(m, "split") or str_eq(m, "lines") {
        return "List$str"
    }
    if str_eq(m, "to_int") {
        return "Result$int$str"
    }
    if str_eq(m, "to_float") {
        return "Result$float$str"
    }
    if obj_custom.startswith("List$") {
        if str_eq(m, "get") or str_eq(m, "pop") or str_eq(m, "remove_at") {
            return obj_custom.slice(5, obj_custom.len())
        }
        return ""
    }
    if obj_custom.startswith("Map$") {
        rest = obj_custom.slice(4, obj_custom.len())
        d = str_find(rest, "$")
        if str_eq(m, "get") {
            return rest.slice(d + 1, rest.len())
        }
        if str_eq(m, "keys") {
            return "List$" + rest.slice(0, d)
        }
        if str_eq(m, "values") {
            return "List$" + rest.slice(d + 1, rest.len())
        }
        return ""
    }
    if str_eq(obj_custom, "str") {
        return ""
    }
    fn = obj_custom + "$" + m
    if g.fn_ret_customs.contains(fn) {
        return g.fn_ret_customs.get(fn)
    }
    return ""
}

public def irg_member_kind(g: @var IRGen, obj: Expr, member: str) -> str {
    obj_custom = irg_expr_type_name(g, obj)
    if obj_custom.len() == 0 or not g.class_fields.contains(obj_custom) {
        return "error"
    }
    names = g.class_fields.get(obj_custom).split(",")
    kinds = g.class_field_types.get(obj_custom).split(",")
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), member) and i < kinds.len() {
            return irg_llvm_kind_of(kinds.get(i))
        }
        i = i + 1
    }
    return "error"
}

public def irg_llvm_kind_of(ty: str) -> str {
    if str_eq(ty, "i64") { return "int" }
    if str_eq(ty, "double") { return "float" }
    if str_eq(ty, "i1") { return "bool" }
    if str_eq(ty, "ptr") { return "str" }
    return "custom"
}

public def irg_member_custom(g: @var IRGen, obj: Expr, member: str) -> str {
    obj_custom = irg_expr_type_name(g, obj)
    if obj_custom.len() == 0 or not g.class_fields.contains(obj_custom) {
        return ""
    }
    names = g.class_fields.get(obj_custom).split(",")
    tys = g.class_field_types.get(obj_custom).split(",")
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), member) and i < tys.len() {
            t = tys.get(i)
            if t.startswith("%") {
                return t.slice(1, t.len())
            }
            return ""
        }
        i = i + 1
    }
    return ""
}

# ---------------------------------------------------------------------------
# Expression code generation
# ---------------------------------------------------------------------------

public def irg_codegen_expr(g: @var IRGen, e: Expr) -> str {
    if e.kind == ExprIntLit() {
        return to_string(e.int_val)
    } elif e.kind == ExprFloatLit() {
        return float_const(e.float_val)
    } elif e.kind == ExprBoolLit() {
        if e.bool_val {
            return "true"
        }
        return "false"
    } elif e.kind == ExprStringLit() {
        return irg_emit_string_const(g, e.str_val)
    } elif e.kind == ExprNoneLit() {
        return "0"
    } elif e.kind == ExprVar() {
        return irg_load_var(g, e.name)
    } elif e.kind == ExprUnary() {
        return irg_codegen_unary(g, e)
    } elif e.kind == ExprBinary() {
        return irg_codegen_binary(g, e)
    } elif e.kind == ExprCall() {
        return irg_codegen_call(g, e)
    } elif e.kind == ExprIf() {
        return irg_codegen_if(g, e)
    } elif e.kind == ExprBlock() {
        return irg_codegen_block(g, e)
    } elif e.kind == ExprAssign() {
        return irg_codegen_assign(g, e)
    } elif e.kind == ExprMatch() {
        return irg_codegen_match(g, e)
    } elif e.kind == ExprMember() {
        return irg_codegen_member(g, e)
    } elif e.kind == ExprBorrow() {
        # @x / @var x: take the variable's address.
        if e.operand.get(0).kind == ExprVar() and g.var_alloca.contains(e.operand.get(0).name) {
            return g.var_alloca.get(e.operand.get(0).name)
        }
        return "null"
    } elif e.kind == ExprTry() {
        return irg_codegen_try(g, e)
    } elif e.kind == ExprAwait() {
        if e.operand.len() == 0 {
            return "0"
        }
        return irg_codegen_await_value(g, e.operand.get(0))
    }
    return "0"
}

# `expr?`: on failure return Err early; on success take out the Ok payload.
public def irg_codegen_try(g: @var IRGen, e: Expr) -> str {
    op = e.operand.get(0)
    op_enum = irg_expr_type_name_ref(g, @op)
    fn_enum = g.fn_ret_custom
    if op_enum.len() == 0 or fn_enum.len() == 0 {
        return "0"
    }
    irg_ensure_enum_layout(g, op_enum)
    irg_ensure_type(g, op_enum)

    op_ptr = irg_object_ptr(g, e.operand.get(0))
    if op_ptr.len() == 0 {
        v = irg_codegen_expr(g, e.operand.get(0))
        op_ptr = irg_materialize_ptr(g, e.operand.get(0), v, op_enum)
    }
    disc_p = irg_new_reg(g)
    irg_add(g, disc_p + " = getelementptr %" + op_enum + ", ptr " + op_ptr +
              ", i32 0, i32 0")
    disc = irg_new_reg(g)
    irg_add(g, disc + " = load i8, ptr " + disc_p)
    slot_p = irg_new_reg(g)
    irg_add(g, slot_p + " = getelementptr %" + op_enum + ", ptr " + op_ptr +
              ", i32 0, i32 1, i32 0")
    raw = irg_new_reg(g)
    irg_add(g, raw + " = load i64, ptr " + slot_p)

    ok_label = irg_new_label(g, "try.ok")
    err_label = irg_new_label(g, "try.err")
    is_err = irg_new_reg(g)
    irg_add(g, is_err + " = icmp eq i8 " + disc + ", 1")
    irg_add(g, "br i1 " + is_err + ", label %" + err_label + ", label %" + ok_label)

    # Err(e): reuse the error payload slot to construct the current function's return type.
    irg_add(g, err_label + ":")
    irg_ensure_enum_layout(g, fn_enum)
    irg_ensure_type(g, fn_enum)
    ra = irg_new_reg(g)
    irg_add(g, ra + " = alloca %" + fn_enum)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = getelementptr %" + fn_enum + ", ptr " + ra +
              ", i32 0, i32 0")
    irg_add(g, "store i8 1, ptr " + fd)
    fp = irg_new_reg(g)
    irg_add(g, fp + " = getelementptr %" + fn_enum + ", ptr " + ra +
              ", i32 0, i32 1, i32 0")
    irg_add(g, "store i64 " + raw + ", ptr " + fp)
    fv = irg_new_reg(g)
    irg_add(g, fv + " = load %" + fn_enum + ", ptr " + ra)
    irg_add(g, "ret %" + fn_enum + " " + fv)

    irg_add(g, ok_label + ":")
    rest = op_enum.slice(7, op_enum.len())
    d = str_find(rest, "$")
    ok_elem = rest.slice(0, d)
    if str_eq(ok_elem, "float") {
        r = irg_new_reg(g)
        irg_add(g, r + " = bitcast i64 " + raw + " to double")
        return r
    }
    if str_eq(ok_elem, "bool") {
        r = irg_new_reg(g)
        irg_add(g, r + " = trunc i64 " + raw + " to i1")
        return r
    }
    if str_eq(ok_elem, "str") {
        r = irg_new_reg(g)
        irg_add(g, r + " = inttoptr i64 " + raw + " to ptr")
        return r
    }
    return raw
}

# Float constant formatting.
public def float_const(v: float) -> str {
    s = to_string(v)
    has_dot = False
    has_e = False
    i = 0
    while i < s.len() {
        if s.char_at(i) == ".".char_at(0) {
            has_dot = True
        }
        if s.char_at(i) == "e".char_at(0) or s.char_at(i) == "E".char_at(0) {
            has_e = True
        }
        i = i + 1
    }
    if not has_dot and not has_e {
        s = s + ".0"
    }
    return s
}

public def irg_load_var(g: @var IRGen, name: str) -> str {
    if not g.var_alloca.contains(name) {
        return "0"
    }
    alloca = g.var_alloca.get(name)
    # Pointer-typed variables like `self`: the alloca stores a pointer to the custom type.
    if g.var_is_ptr.contains(name) and g.var_is_ptr.get(name) == 1 {
        r = irg_new_reg(g)
        irg_add(g, r + " = load ptr, ptr " + alloca)
        return r
    }
    kind = g.var_kind.get(name)
    ty = ""
    if str_eq(kind, "custom") {
        ty = "%" + g.var_type_name.get(name)
    } else {
        ty = irg_llvm_type_of_kind(kind)
    }
    r = irg_new_reg(g)
    irg_add(g, r + " = load " + ty + ", ptr " + alloca)
    return r
}

public def irg_llvm_type_of_kind(kind: str) -> str {
    if str_eq(kind, "int") { return "i64" }
    if str_eq(kind, "float") { return "double" }
    if str_eq(kind, "bool") { return "i1" }
    if str_eq(kind, "str") { return "ptr" }
    if str_eq(kind, "None") { return "i64" }
    return "i64"
}

public def irg_codegen_unary(g: @var IRGen, e: Expr) -> str {
    v = irg_codegen_expr(g, e.operand.get(0))
    if str_eq(e.op, "not") {
        r = irg_new_reg(g)
        irg_add(g, r + " = xor i1 " + v + ", true")
        return r
    }
    # negation.
    k = irg_expr_kind(g, e.operand.get(0))
    if str_eq(k, "float") {
        r = irg_new_reg(g)
        irg_add(g, r + " = fneg double " + v)
        return r
    }
    r = irg_new_reg(g)
    irg_add(g, r + " = sub i64 0, " + v)
    return r
}

public def irg_codegen_binary(g: @var IRGen, e: Expr) -> str {
    lk = irg_expr_kind(g, e.lhs.get(0))
    rk = irg_expr_kind(g, e.rhs.get(0))

    # string concatenation.
    if str_eq(e.op, "+") and (str_eq(lk, "str") or str_eq(rk, "str")) {
        l = irg_codegen_expr(g, e.lhs.get(0))
        r = irg_codegen_expr(g, e.rhs.get(0))
        return irg_string_concat(g, l, r)
    }

    # and / or: short-circuit evaluation, merging results in an alloca.
    if str_eq(e.op, "and") or str_eq(e.op, "or") {
        l = irg_codegen_expr(g, e.lhs.get(0))
        res_a = irg_new_reg(g)
        irg_add(g, res_a + " = alloca i1")
        irg_add(g, "store i1 " + l + ", ptr " + res_a)
        rhs_label = irg_new_label(g, "logic.rhs")
        end_label = irg_new_label(g, "logic.end")
        if str_eq(e.op, "and") {
            irg_add(g, "br i1 " + l + ", label %" + rhs_label + ", label %" + end_label)
        } else {
            irg_add(g, "br i1 " + l + ", label %" + end_label + ", label %" + rhs_label)
        }
        irg_add(g, rhs_label + ":")
        r = irg_codegen_expr(g, e.rhs.get(0))
        irg_add(g, "store i1 " + r + ", ptr " + res_a)
        irg_add(g, "br label %" + end_label)
        irg_add(g, end_label + ":")
        out = irg_new_reg(g)
        irg_add(g, out + " = load i1, ptr " + res_a)
        return out
    }

    # bitwise operations.
    if str_eq(e.op, "&") or str_eq(e.op, "|") or
       str_eq(e.op, "^") or str_eq(e.op, "<<") or str_eq(e.op, ">>") {
        l = irg_codegen_expr(g, e.lhs.get(0))
        r = irg_codegen_expr(g, e.rhs.get(0))
        res = irg_new_reg(g)
        if str_eq(e.op, "&") {
            irg_add(g, res + " = and i64 " + l + ", " + r)
        } elif str_eq(e.op, "|") {
            irg_add(g, res + " = or i64 " + l + ", " + r)
        } elif str_eq(e.op, "^") {
            irg_add(g, res + " = xor i64 " + l + ", " + r)
        } elif str_eq(e.op, "<<") {
            irg_add(g, res + " = shl i64 " + l + ", " + r)
        } else {
            irg_add(g, res + " = ashr i64 " + l + ", " + r)
        }
        return res
    }

    is_float = str_eq(lk, "float") or str_eq(rk, "float")

    # comparisons.
    if str_eq(e.op, "==") or str_eq(e.op, "!=") or
       str_eq(e.op, "<") or str_eq(e.op, "<=") or
       str_eq(e.op, ">") or str_eq(e.op, ">=") {
        l = irg_codegen_expr(g, e.lhs.get(0))
        r = irg_codegen_expr(g, e.rhs.get(0))
        res = irg_new_reg(g)
        # string equality: compare by content.
        if (str_eq(e.op, "==") or str_eq(e.op, "!=")) and
           str_eq(lk, "str") and str_eq(rk, "str") {
            cmp = irg_new_reg(g)
            irg_add(g, cmp + " = call i32 @strcmp(ptr " + l + ", ptr " + r + ")")
            if str_eq(e.op, "==") {
                irg_add(g, res + " = icmp eq i32 " + cmp + ", 0")
            } else {
                irg_add(g, res + " = icmp ne i32 " + cmp + ", 0")
            }
            return res
        }
        # enum comparison: compare discriminants.
        if str_eq(lk, "custom") and str_eq(rk, "custom") {
            # two enum values: load and compare the discs.
            lp = irg_materialize_ptr(g, e.lhs.get(0), l, irg_expr_type_name(g, e.lhs.get(0)))
            rp = irg_materialize_ptr(g, e.rhs.get(0), r, irg_expr_type_name(g, e.rhs.get(0)))
            ld = irg_new_reg(g)
            irg_add(g, ld + " = getelementptr i8, ptr " + lp + ", i32 0")
            lv = irg_new_reg(g)
            irg_add(g, lv + " = load i8, ptr " + ld)
            rd = irg_new_reg(g)
            irg_add(g, rd + " = getelementptr i8, ptr " + rp + ", i32 0")
            rv = irg_new_reg(g)
            irg_add(g, rv + " = load i8, ptr " + rd)
            if str_eq(e.op, "==") {
                irg_add(g, res + " = icmp eq i8 " + lv + ", " + rv)
            } else {
                irg_add(g, res + " = icmp ne i8 " + lv + ", " + rv)
            }
            return res
        }
        if is_float {
            if str_eq(lk, "int") {
                lf = irg_new_reg(g)
                irg_add(g, lf + " = sitofp i64 " + l + " to double")
                l = lf
            }
            if str_eq(rk, "int") {
                rf = irg_new_reg(g)
                irg_add(g, rf + " = sitofp i64 " + r + " to double")
                r = rf
            }
            pred = ""
            if str_eq(e.op, "==") { pred = "oeq" }
            elif str_eq(e.op, "!=") { pred = "one" }
            elif str_eq(e.op, "<") { pred = "olt" }
            elif str_eq(e.op, "<=") { pred = "ole" }
            elif str_eq(e.op, ">") { pred = "ogt" }
            else { pred = "oge" }
            irg_add(g, res + " = fcmp " + pred + " double " + l + ", " + r)
            return res
        }
        pred = ""
        if str_eq(e.op, "==") { pred = "eq" }
        elif str_eq(e.op, "!=") { pred = "ne" }
        elif str_eq(e.op, "<") { pred = "slt" }
        elif str_eq(e.op, "<=") { pred = "sle" }
        elif str_eq(e.op, ">") { pred = "sgt" }
        else { pred = "sge" }
        irg_add(g, res + " = icmp " + pred + " i64 " + l + ", " + r)
        return res
    }

    l = irg_codegen_expr(g, e.lhs.get(0))
    r = irg_codegen_expr(g, e.rhs.get(0))

    # ** exponentiation.
    if str_eq(e.op, "**") {
        lf = irg_new_reg(g)
        irg_add(g, lf + " = sitofp i64 " + l + " to double")
        rf = irg_new_reg(g)
        irg_add(g, rf + " = sitofp i64 " + r + " to double")
        pw = irg_new_reg(g)
        irg_add(g, pw + " = call double @llvm.pow.f64(double " + lf + ", double " + rf + ")")
        if is_float {
            return pw
        }
        res = irg_new_reg(g)
        irg_add(g, res + " = fptosi double " + pw + " to i64")
        return res
    }

    if is_float {
        if str_eq(lk, "int") {
            lf = irg_new_reg(g)
            irg_add(g, lf + " = sitofp i64 " + l + " to double")
            l = lf
        }
        if str_eq(rk, "int") {
            rf = irg_new_reg(g)
            irg_add(g, rf + " = sitofp i64 " + r + " to double")
            r = rf
        }
        res = irg_new_reg(g)
        if str_eq(e.op, "+") {
            irg_add(g, res + " = fadd double " + l + ", " + r)
        } elif str_eq(e.op, "-") {
            irg_add(g, res + " = fsub double " + l + ", " + r)
        } elif str_eq(e.op, "*") {
            irg_add(g, res + " = fmul double " + l + ", " + r)
        } elif str_eq(e.op, "/") or str_eq(e.op, "//") {
            irg_add(g, res + " = fdiv double " + l + ", " + r)
        } else {
            irg_add(g, res + " = frem double " + l + ", " + r)
        }
        return res
    }

    res = irg_new_reg(g)
    if str_eq(e.op, "+") {
        irg_add(g, res + " = add i64 " + l + ", " + r)
    } elif str_eq(e.op, "-") {
        irg_add(g, res + " = sub i64 " + l + ", " + r)
    } elif str_eq(e.op, "*") {
        irg_add(g, res + " = mul i64 " + l + ", " + r)
    } elif str_eq(e.op, "/") or str_eq(e.op, "//") {
        irg_add(g, res + " = sdiv i64 " + l + ", " + r)
    } else {
        irg_add(g, res + " = srem i64 " + l + ", " + r)
    }
    return res
}

# Put an expression value into a temporary alloca and return its address.
public def irg_materialize_ptr(g: @var IRGen, e: Expr, val: str, custom: str) -> str {
    kind = irg_expr_kind(g, e)
    ty = ""
    if str_eq(kind, "custom") {
        ty = "%" + custom
    } else {
        ty = irg_llvm_type_of_kind(kind)
    }
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca " + ty)
    irg_add(g, "store " + ty + " " + val + ", ptr " + a)
    return a
}

# String concatenation s1 + s2.
public def irg_string_concat(g: @var IRGen, l: str, r: str) -> str {
    l1 = irg_new_reg(g)
    irg_add(g, l1 + " = call i64 @strlen(ptr " + l + ")")
    l2 = irg_new_reg(g)
    irg_add(g, l2 + " = call i64 @strlen(ptr " + r + ")")
    total = irg_new_reg(g)
    irg_add(g, total + " = add i64 " + l1 + ", " + l2)
    n1 = irg_new_reg(g)
    irg_add(g, n1 + " = add i64 " + total + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + n1 + ")")
    x = irg_new_reg(g)
    irg_add(g, x + " = call ptr @memcpy(ptr " + buf + ", ptr " + l + ", i64 " + l1 + ")")
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + l1)
    x = irg_new_reg(g)
    irg_add(g, x + " = call ptr @memcpy(ptr " + dst + ", ptr " + r + ", i64 " + l2 + ")")
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + total)
    irg_add(g, "store i8 0, ptr " + nul)
    return buf
}

# Object pointer (variable alloca / member GEP / temporary materialization).
public def irg_object_ptr(g: @var IRGen, e: Expr) -> str {
    if e.kind == ExprVar() {
        if g.var_alloca.contains(e.name) {
            if g.var_is_ptr.contains(e.name) and g.var_is_ptr.get(e.name) == 1 {
                # self / borrow parameters: load the class pointer from the alloca.
                r = irg_new_reg(g)
                irg_add(g, r + " = load ptr, ptr " + g.var_alloca.get(e.name))
                return r
            }
            return g.var_alloca.get(e.name)
        }
        return ""
    }
    if e.kind == ExprMember() {
        return irg_member_ptr(g, e.object.get(0), e.name)
    }
    if e.kind == ExprBorrow() {
        # @x / @var x: the borrow expression already evaluates to the variable's address.
        op = e.operand.get(0)
        if op.kind == ExprVar() and g.var_alloca.contains(op.name) {
            if g.var_is_ptr.contains(op.name) and g.var_is_ptr.get(op.name) == 1 {
                r = irg_new_reg(g)
                irg_add(g, r + " = load ptr, ptr " + g.var_alloca.get(op.name))
                return r
            }
            return g.var_alloca.get(op.name)
        }
        return ""
    }
    return ""
}

public def irg_member_ptr(g: @var IRGen, obj: Expr, member: str) -> str {
    # Use the borrowing variant's type name to avoid moving obj before taking its pointer.
    obj_custom = irg_expr_type_name_ref(g, @obj)
    if obj_custom.len() == 0 or not g.class_fields.contains(obj_custom) {
        return ""
    }
    names = g.class_fields.get(obj_custom).split(",")
    idx = 0
    found = False
    i = 0
    while i < names.len() {
        if str_eq(names.get(i), member) {
            idx = i
            found = True
            break
        }
        i = i + 1
    }
    if not found {
        return ""
    }
    base = ""
    if obj.kind == ExprVar() {
        if g.var_alloca.contains(obj.name) {
            if g.var_is_ptr.contains(obj.name) and g.var_is_ptr.get(obj.name) == 1 {
                r = irg_new_reg(g)
                irg_add(g, r + " = load ptr, ptr " + g.var_alloca.get(obj.name))
                base = r
            } else {
                base = g.var_alloca.get(obj.name)
            }
        }
    } elif obj.kind == ExprMember() {
        base = irg_member_ptr(g, obj.object.get(0), obj.name)
    }
    if base.len() == 0 {
        # temporary objects (e.g. function call results): materialize their value (moving obj is the last use).
        v = irg_codegen_expr(g, obj)
        a = irg_new_reg(g)
        irg_add(g, a + " = alloca %" + obj_custom)
        irg_add(g, "store %" + obj_custom + " " + v + ", ptr " + a)
        base = a
    }
    p = irg_new_reg(g)
    irg_add(g, p + " = getelementptr %" + obj_custom + ", ptr " + base +
              ", i32 0, i32 " + to_string(idx))
    return p
}

public def irg_codegen_member(g: @var IRGen, e: Expr) -> str {
    obj_custom = irg_expr_type_name(g, e.object.get(0))
    kind = irg_member_kind(g, e.object.get(0), e.name)
    p = irg_member_ptr(g, e.object.get(0), e.name)
    if p.len() == 0 {
        return "0"
    }
    ty = ""
    if str_eq(kind, "custom") {
        ty = "%" + irg_member_custom(g, e.object.get(0), e.name)
    } else {
        ty = irg_llvm_type_of_kind(kind)
    }
    r = irg_new_reg(g)
    irg_add(g, r + " = load " + ty + ", ptr " + p)
    return r
}

# Borrow variables and borrow parameters store an object pointer, so irg_load_var
# yields a `ptr`; a class-typed value copy needs the pointee loaded out of it.
public def irg_copy_class_value(g: @var IRGen, e: Expr, v: str) -> str {
    if e.kind == ExprVar() and g.var_is_ptr.contains(e.name) and g.var_is_ptr.get(e.name) == 1 {
        tn = g.var_type_name.get(e.name)
        if tn.len() > 0 {
            r = irg_new_reg(g)
            irg_add(g, r + " = load %" + tn + ", ptr " + v)
            return r
        }
    }
    return v
}

public def irg_codegen_assign(g: @var IRGen, e: Expr) -> str {
    val = irg_codegen_expr(g, e.value.get(0))
    vk = irg_expr_kind(g, e.value.get(0))
    vcustom = irg_expr_type_name(g, e.value.get(0))

    # member assignment.
    if e.target.len() > 0 {
        tg = e.target.get(0)
        p = irg_member_ptr(g, tg.object.get(0), tg.name)
        kind = irg_member_kind(g, tg.object.get(0), tg.name)
        ty = ""
        if str_eq(kind, "custom") {
            ty = "%" + irg_member_custom(g, tg.object.get(0), tg.name)
            val = irg_copy_class_value(g, e.value.get(0), val)
        } else {
            ty = irg_llvm_type_of_kind(kind)
        }
        if e.value.get(0).kind == ExprNoneLit() {
            if ty.startswith("%") {
                val = "zeroinitializer"
            } elif str_eq(ty, "ptr") {
                val = "null"
            }
        }
        # numeric promotion: int -> float.
        if str_eq(ty, "double") and not str_eq(vk, "float") {
            cv = irg_new_reg(g)
            irg_add(g, cv + " = sitofp i64 " + val + " to double")
            val = cv
        }
        irg_add(g, "store " + ty + " " + val + ", ptr " + p)
        return val
    }

    # existing variable: re-assignment.
    if g.var_alloca.contains(e.name) {
        kind = g.var_kind.get(e.name)
        ty = ""
        if str_eq(kind, "custom") {
            ty = "%" + g.var_type_name.get(e.name)
            val = irg_copy_class_value(g, e.value.get(0), val)
        } else {
            ty = irg_llvm_type_of_kind(kind)
        }
        if e.value.get(0).kind == ExprNoneLit() {
            if ty.startswith("%") {
                val = "zeroinitializer"
            } elif str_eq(ty, "ptr") {
                val = "null"
            }
        }
        if str_eq(ty, "double") and not str_eq(vk, "float") {
            cv = irg_new_reg(g)
            irg_add(g, cv + " = sitofp i64 " + val + " to double")
            val = cv
        }
        irg_add(g, "store " + ty + " " + val + ", ptr " + g.var_alloca.get(e.name))
        return val
    }

    # borrow binding: r = @x / r = @var x; the variable stores an object pointer.
    if e.value.get(0).kind == ExprBorrow() {
        bop = e.value.get(0).operand.get(0)
        bcustom = irg_expr_type_name(g, bop)
        a = irg_new_reg(g)
        irg_add(g, a + " = alloca ptr")
        irg_add(g, "store ptr " + val + ", ptr " + a)
        g.var_alloca.put(e.name, a)
        g.var_kind.put(e.name, "custom")
        g.var_type_name.put(e.name, bcustom)
        g.var_is_ptr.put(e.name, 1)
        irg_dbg_declare(g, e.name, a, "custom", bcustom, e.line)
        return val
    }

    # new variable declaration.
    kind = vk
    custom = vcustom
    if e.type_ann.name.len() > 0 {
        kind = type_kind_of_te(e.type_ann)
        if str_eq(kind, "custom") {
            custom = irg_te_mangled(g, e.type_ann)
        } else {
            custom = ""
        }
    }
    ty = ""
    if str_eq(kind, "custom") {
        ty = "%" + custom
        val = irg_copy_class_value(g, e.value.get(0), val)
    } else {
        ty = irg_llvm_type_of_kind(kind)
    }
    if e.value.get(0).kind == ExprNoneLit() {
        if ty.startswith("%") {
            val = "zeroinitializer"
        } elif str_eq(ty, "ptr") {
            val = "null"
        }
    }
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca " + ty)
    irg_add(g, "store " + ty + " " + val + ", ptr " + a)
    g.var_alloca.put(e.name, a)
    g.var_kind.put(e.name, kind)
    g.var_type_name.put(e.name, custom)
    irg_dbg_declare(g, e.name, a, kind, custom, e.line)
    return val
}

# Generate code for block expressions.
public def irg_codegen_block(g: @var IRGen, e: Expr) -> str {
    i = 0
    while i < e.stmts.len() {
        irg_codegen_stmt(g, e.stmts.get(i))
        if irg_is_terminated(g) {
            break
        }
        i = i + 1
    }
    if irg_is_terminated(g) {
        return "0"
    }
    if e.result.len() > 0 {
        if e.result.get(0).kind == ExprIf() {
            # an if at the end of a block is still a statement (if expressions are not used in the current source).
            ri = e.result.get(0)
            irg_codegen_if_stmt(g, ri)
            return "0"
        }
        return irg_codegen_expr(g, e.result.get(0))
    }
    return "0"
}

# if statements: ignore branch results; control flow only.
public def irg_codegen_if_stmt(g: @var IRGen, e: Expr) {
    cond = irg_codegen_expr(g, e.cond.get(0))
    then_label = irg_new_label(g, "if.then")
    else_label = irg_new_label(g, "if.else")
    merge_label = irg_new_label(g, "if.end")
    irg_add(g, "br i1 " + cond + ", label %" + then_label + ", label %" + else_label)

    irg_add(g, then_label + ":")
    irg_codegen_expr(g, e.then_block.get(0))
    then_done = irg_is_terminated(g)
    if not then_done {
        irg_add(g, "br label %" + merge_label)
    }

    irg_add(g, else_label + ":")
    if e.else_block.len() > 0 {
        if e.else_block.get(0).kind == ExprIf() {
            ei = e.else_block.get(0)
            irg_codegen_if_stmt(g, ei)
        } else {
            irg_codegen_expr(g, e.else_block.get(0))
        }
    }
    else_done = irg_is_terminated(g)
    if not else_done {
        irg_add(g, "br label %" + merge_label)
    }

    if then_done and else_done {
        return
    }
    irg_add(g, merge_label + ":")
}

# if expressions: merge with an alloca to avoid PHI.
public def irg_codegen_if(g: @var IRGen, e: Expr) -> str {
    cond = irg_codegen_expr(g, e.cond.get(0))
    then_label = irg_new_label(g, "if.then")
    else_label = irg_new_label(g, "if.else")
    merge_label = irg_new_label(g, "if.end")

    # result type.
    tk = irg_expr_kind(g, e.then_block.get(0))
    if str_eq(tk, "error") {
        tk = "int"
    }
    ty = ""
    custom = ""
    if str_eq(tk, "custom") {
        custom = irg_expr_type_name(g, e.then_block.get(0))
        ty = "%" + custom
    } else {
        ty = irg_llvm_type_of_kind(tk)
    }
    res_alloca = irg_new_reg(g)
    irg_add(g, res_alloca + " = alloca " + ty)
    irg_add(g, "br i1 " + cond + ", label %" + then_label + ", label %" + else_label)

    irg_add(g, then_label + ":")
    tv = irg_codegen_expr(g, e.then_block.get(0))
    then_done = irg_is_terminated(g)
    if not then_done {
        irg_add(g, "store " + ty + " " + tv + ", ptr " + res_alloca)
        irg_add(g, "br label %" + merge_label)
    }

    irg_add(g, else_label + ":")
    ev = irg_zero_value(ty)
    if e.else_block.len() > 0 {
        ev = irg_codegen_expr(g, e.else_block.get(0))
        ek = irg_expr_kind(g, e.else_block.get(0))
        if str_eq(ek, "custom") {
            ety = "%" + irg_expr_type_name(g, e.else_block.get(0))
            # types should match; ignored when they do not.
            ev = ev
        }
    }
    else_done = irg_is_terminated(g)
    if not else_done {
        irg_add(g, "store " + ty + " " + ev + ", ptr " + res_alloca)
        irg_add(g, "br label %" + merge_label)
    }

    # both branches returned: the if expression itself terminates; no join block is needed.
    if then_done and else_done {
        return "0"
    }

    irg_add(g, merge_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load " + ty + ", ptr " + res_alloca)
    return r
}

# match statements: ignore arm results; generate control flow only.
def irg_codegen_match_stmt(g: @var IRGen, e: Expr) {
    enum_name = irg_expr_type_name(g, e.subject.get(0))
    if enum_name.len() == 0 {
        return
    }
    irg_ensure_enum_layout(g, enum_name)
    irg_ensure_type(g, enum_name)
    subj_ptr = irg_object_ptr(g, e.subject.get(0))
    if subj_ptr.len() == 0 {
        sv = irg_codegen_expr(g, e.subject.get(0))
        subj_ptr = irg_materialize_ptr(g, e.subject.get(0), sv, enum_name)
    }
    disc_ptr = irg_new_reg(g)
    irg_add(g, disc_ptr + " = getelementptr %" + enum_name + ", ptr " + subj_ptr +
              ", i32 0, i32 0")
    disc = irg_new_reg(g)
    irg_add(g, disc + " = load i8, ptr " + disc_ptr)

    merge_label = irg_new_label(g, "match.end")
    else_label = irg_new_label(g, "match.else")
    variant_arms = List[MatchArm]()
    wildcard_arm = make_match_arm(make_pattern_wildcard(), none_expr())
    has_wildcard = False
    i = 0
    while i < e.arms.len() {
        arm = e.arms.get(i)
        if arm.pattern.kind == PatternWildcard() {
            wildcard_arm = arm
            has_wildcard = True
        } else {
            variant_arms.push(arm)
        }
        i = i + 1
    }
    i = 0
    while i < variant_arms.len() {
        arm = variant_arms.get(i)
        v_idx = irg_builtin_variant_idx(enum_name, arm.pattern.name)
        if v_idx < 0 and g.enum_variant_idx.contains(arm.pattern.name) {
            v_idx = g.enum_variant_idx.get(arm.pattern.name)
        }
        next_label = irg_new_label(g, "match.test")
        if i + 1 >= variant_arms.len() {
            next_label = else_label
        }
        if v_idx >= 0 {
            arm_label = irg_new_label(g, "match.arm")
            c = irg_new_reg(g)
            irg_add(g, c + " = icmp eq i8 " + disc + ", " + to_string(v_idx))
            irg_add(g, "br i1 " + c + ", label %" + arm_label + ", label %" + next_label)
            irg_add(g, arm_label + ":")
            irg_codegen_match_arm(g, arm, enum_name, subj_ptr, "i64")
            if not irg_is_terminated(g) {
                irg_add(g, "br label %" + merge_label)
            }
        }
        if i + 1 < variant_arms.len() {
            irg_add(g, next_label + ":")
        }
        i = i + 1
    }
    irg_add(g, else_label + ":")
    if has_wildcard {
        irg_codegen_match_arm(g, wildcard_arm, enum_name, subj_ptr, "i64")
    }
    if not irg_is_terminated(g) {
        irg_add(g, "br label %" + merge_label)
    }
    irg_add(g, merge_label + ":")
}

# match expressions.
public def irg_codegen_match(g: @var IRGen, e: Expr) -> str {
    enum_name = irg_expr_type_name(g, e.subject.get(0))
    if enum_name.len() == 0 {
        return "0"
    }
    irg_ensure_enum_layout(g, enum_name)
    irg_ensure_type(g, enum_name)

    # materialize the subject pointer.
    subj_ptr = irg_object_ptr(g, e.subject.get(0))
    if subj_ptr.len() == 0 {
        sv = irg_codegen_expr(g, e.subject.get(0))
        subj_ptr = irg_materialize_ptr(g, e.subject.get(0), sv, enum_name)
    }

    disc_ptr = irg_new_reg(g)
    irg_add(g, disc_ptr + " = getelementptr %" + enum_name + ", ptr " + subj_ptr +
              ", i32 0, i32 0")
    disc = irg_new_reg(g)
    irg_add(g, disc + " = load i8, ptr " + disc_ptr)

    merge_label = irg_new_label(g, "match.end")
    else_label = irg_new_label(g, "match.else")

    # result type: take the first arm body's type.
    rk = "int"
    rcustom = ""
    if e.arms.len() > 0 {
        rk = irg_expr_kind(g, e.arms.get(0).body)
        if str_eq(rk, "custom") {
            rcustom = irg_expr_type_name(g, e.arms.get(0).body)
        }
    }
    if str_eq(rk, "error") {
        rk = "int"
    }
    rty = ""
    if str_eq(rk, "custom") {
        rty = "%" + rcustom
    } else {
        rty = irg_llvm_type_of_kind(rk)
    }
    res_alloca = irg_new_reg(g)
    irg_add(g, res_alloca + " = alloca " + rty)

    # separate variant arms from the wildcard.
    variant_arms = List[MatchArm]()
    wildcard_arm = make_match_arm(make_pattern_wildcard(), none_expr())
    has_wildcard = False
    i = 0
    while i < e.arms.len() {
        arm = e.arms.get(i)
        if arm.pattern.kind == PatternWildcard() {
            wildcard_arm = arm
            has_wildcard = True
        } else {
            variant_arms.push(arm)
        }
        i = i + 1
    }

    # variant if-else chain.
    test_label = irg_new_label(g, "match.test")
    irg_add(g, "br label %" + test_label)
    irg_add(g, test_label + ":")
    i = 0
    while i < variant_arms.len() {
        arm = variant_arms.get(i)
        v_idx = irg_builtin_variant_idx(enum_name, arm.pattern.name)
        if v_idx < 0 and g.enum_variant_idx.contains(arm.pattern.name) and
           str_eq(g.enum_variant_enum.get(arm.pattern.name), enum_name) {
            v_idx = g.enum_variant_idx.get(arm.pattern.name)
        }
        next_label = irg_new_label(g, "match.test")
        if i + 1 >= variant_arms.len() {
            next_label = else_label
        }
        if v_idx >= 0 {
            arm_label = irg_new_label(g, "match.arm")
            c = irg_new_reg(g)
            irg_add(g, c + " = icmp eq i8 " + disc + ", " + to_string(v_idx))
            irg_add(g, "br i1 " + c + ", label %" + arm_label + ", label %" + next_label)
            irg_add(g, arm_label + ":")
            av = irg_codegen_match_arm(g, arm, enum_name, subj_ptr, rty)
            irg_add(g, "store " + rty + " " + av + ", ptr " + res_alloca)
            irg_add(g, "br label %" + merge_label)
        }
        if i + 1 < variant_arms.len() {
            irg_add(g, next_label + ":")
        }
        test_label = next_label
        i = i + 1
    }

    # else / wildcard.
    irg_add(g, else_label + ":")
    ev = irg_zero_value(rty)
    if has_wildcard {
        ev = irg_codegen_match_arm(g, wildcard_arm, enum_name, subj_ptr, rty)
    }
    irg_add(g, "store " + rty + " " + ev + ", ptr " + res_alloca)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, merge_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load " + rty + ", ptr " + res_alloca)
    return r
}

public def irg_codegen_match_arm(g: @var IRGen, arm: MatchArm, enum_name: str, subj_ptr: str,
                          rty: str) -> str {
    if arm.pattern.kind == PatternVariant() {
        kinds_all = g.enum_field_kinds.get(enum_name).split("|")
        names_all = g.enum_field_names.get(enum_name).split("|")
        if arm.pattern.named_fields {
            # named patterns: locate the slot by field name.
            fnames = kinds_all_slot_names(g, enum_name, arm.pattern.name)
            i = 0
            while i < arm.pattern.fields.len() and i < arm.pattern.field_names.len() {
                sub = arm.pattern.fields.get(i)
                fname = arm.pattern.field_names.get(i)
                slot = -1
                j = 0
                while j < fnames.len() {
                    if str_eq(fnames.get(j), fname) {
                        slot = j
                        break
                    }
                    j = j + 1
                }
                if sub.kind == PatternVar() and slot >= 0 {
                    kinds = kinds_all.get(arm_variant_index(g, arm.pattern.name)).split(",")
                    if slot < kinds.len() {
                        irg_bind_payload(g, sub.name, kinds.get(slot), enum_name, subj_ptr, slot)
                    }
                }
                i = i + 1
            }
        } else {
            v_idx = arm_variant_index(g, arm.pattern.name)
            kinds = kinds_all.get(v_idx).split(",")
            i = 0
            while i < arm.pattern.fields.len() and i < kinds.len() {
                sub = arm.pattern.fields.get(i)
                if sub.kind == PatternVar() {
                    irg_bind_payload(g, sub.name, kinds.get(i), enum_name, subj_ptr, i)
                }
                i = i + 1
            }
        }
    } elif arm.pattern.kind == PatternVar() {
        # bind the whole enum value.
        val = irg_new_reg(g)
        irg_add(g, val + " = load %" + enum_name + ", ptr " + subj_ptr)
        a = irg_new_reg(g)
        irg_add(g, a + " = alloca %" + enum_name)
        irg_add(g, "store %" + enum_name + " " + val + ", ptr " + a)
        g.var_alloca.put(arm.pattern.name, a)
        g.var_kind.put(arm.pattern.name, "custom")
        g.var_type_name.put(arm.pattern.name, enum_name)
        irg_dbg_declare(g, arm.pattern.name, a, "custom", enum_name, 0)
    }
    return irg_codegen_expr(g, arm.body)
}

public def arm_variant_index(g: @var IRGen, name: str) -> int {
    if g.enum_variant_idx.contains(name) {
        return g.enum_variant_idx.get(name)
    }
    return 0
}

# Variant slot name list.
public def kinds_all_slot_names(g: @var IRGen, enum_name: str, variant: str) -> List[str] {
    names_all = g.enum_field_names.get(enum_name).split("|")
    v_idx = arm_variant_index(g, variant)
    if v_idx < names_all.len() {
        return names_all.get(v_idx).split(",")
    }
    return List[str]()
}

# Bind enum payload fields to variables.
public def irg_bind_payload(g: @var IRGen, name: str, kind: str, enum_name: str, subj_ptr: str,
                   slot: int) {
    slot_ptr = irg_new_reg(g)
    irg_add(g, slot_ptr + " = getelementptr %" + enum_name + ", ptr " + subj_ptr +
              ", i32 0, i32 1, i32 " + to_string(slot))
    ty = ""
    val = ""
    if str_eq(kind, "float") {
        raw = irg_new_reg(g)
        irg_add(g, raw + " = load i64, ptr " + slot_ptr)
        val = irg_new_reg(g)
        irg_add(g, val + " = bitcast i64 " + raw + " to double")
        ty = "double"
    } elif str_eq(kind, "bool") {
        raw = irg_new_reg(g)
        irg_add(g, raw + " = load i64, ptr " + slot_ptr)
        val = irg_new_reg(g)
        irg_add(g, val + " = trunc i64 " + raw + " to i1")
        ty = "i1"
    } elif str_eq(kind, "str") {
        val = irg_new_reg(g)
        irg_add(g, val + " = load ptr, ptr " + slot_ptr)
        ty = "ptr"
    } else {
        val = irg_new_reg(g)
        irg_add(g, val + " = load i64, ptr " + slot_ptr)
        ty = "i64"
    }
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca " + ty)
    irg_add(g, "store " + ty + " " + val + ", ptr " + a)
    g.var_alloca.put(name, a)
    g.var_kind.put(name, kind)
    g.var_type_name.put(name, "")
    irg_dbg_declare(g, name, a, kind, "", 0)
}

# ---------------------------------------------------------------------------
# Call code generation
# ---------------------------------------------------------------------------

# Generic function instance names: supported templates infer type parameters from the first argument.
public def irg_generic_fn_name(g: @var IRGen, e: @Expr) -> str {
    if e.args.len() == 0 {
        return ""
    }
    k = irg_expr_kind(g, e.args.get(0))
    if str_eq(k, "custom") {
        return e.name + "$" + irg_expr_type_name(g, e.args.get(0))
    }
    return e.name + "$" + k
}

# math builtin codegen: abs/min/max use compare+select; the rest use LLVM intrinsics.
public def irg_codegen_math(g: @var IRGen, name: str, e: @Expr) -> str {
    a0 = e.args.get(0)
    k0 = irg_expr_kind_ref(g, @a0)
    v0 = irg_codegen_expr(g, a0)
    if str_eq(name, "abs") {
        if str_eq(k0, "float") {
            r = irg_new_reg(g)
            irg_add(g, r + " = call double @llvm.fabs.f64(double " + v0 + ")")
            return r
        }
        neg = irg_new_reg(g)
        irg_add(g, neg + " = sub i64 0, " + v0)
        cmp = irg_new_reg(g)
        irg_add(g, cmp + " = icmp slt i64 " + v0 + ", 0")
        r = irg_new_reg(g)
        irg_add(g, r + " = select i1 " + cmp + ", i64 " + neg + ", i64 " + v0)
        return r
    }
    if str_eq(name, "sqrt") or str_eq(name, "floor") or str_eq(name, "ceil") {
        f0 = irg_math_to_f64(g, k0, v0)
        fn = "llvm.sqrt.f64"
        if str_eq(name, "floor") {
            fn = "llvm.floor.f64"
        } elif str_eq(name, "ceil") {
            fn = "llvm.ceil.f64"
        }
        r = irg_new_reg(g)
        irg_add(g, r + " = call double @" + fn + "(double " + f0 + ")")
        return r
    }
    a1 = e.args.get(1)
    k1 = irg_expr_kind_ref(g, @a1)
    v1 = irg_codegen_expr(g, a1)
    if str_eq(name, "pow") {
        f0 = irg_math_to_f64(g, k0, v0)
        f1 = irg_math_to_f64(g, k1, v1)
        r = irg_new_reg(g)
        irg_add(g, r + " = call double @llvm.pow.f64(double " + f0 + ", double " + f1 + ")")
        return r
    }
    if str_eq(k0, "float") or str_eq(k1, "float") {
        f0 = irg_math_to_f64(g, k0, v0)
        f1 = irg_math_to_f64(g, k1, v1)
        pred = "olt"
        if str_eq(name, "max") {
            pred = "ogt"
        }
        cmp = irg_new_reg(g)
        irg_add(g, cmp + " = fcmp " + pred + " double " + f0 + ", " + f1)
        r = irg_new_reg(g)
        irg_add(g, r + " = select i1 " + cmp + ", double " + f0 + ", double " + f1)
        return r
    }
    pred = "slt"
    if str_eq(name, "max") {
        pred = "sgt"
    }
    cmp = irg_new_reg(g)
    irg_add(g, cmp + " = icmp " + pred + " i64 " + v0 + ", " + v1)
    r = irg_new_reg(g)
    irg_add(g, r + " = select i1 " + cmp + ", i64 " + v0 + ", i64 " + v1)
    return r
}

public def irg_codegen_call(g: @var IRGen, e: Expr) -> str {
    # Module-qualified calls: Sema already resolved the internal function name.
    key = irg_call_key(@var g, @e)
    if not g.qualified_calls.contains(key) and g.call_syms.contains(key) {
        # Qualified/bare-name calls (including qualified generic instances): call freely by the resolution,
        # avoiding the method-call path (module is not a value).
        target = g.call_syms.get(key)
        if g.fn_ret_kinds.contains(target) {
            return irg_codegen_free_call(g, target, @e)
        }
    }
    if g.qualified_calls.contains(key) {
        qn = g.qualified_calls.get(key)
        if str_eq(qn, "read_file") {
            return irg_codegen_read_file(g, @e)
        }
        if str_eq(qn, "write_file") {
            return irg_codegen_write_file(g, @e)
        }
        if str_eq(qn, "append_file") {
            return irg_codegen_append_file(g, @e)
        }
        if str_eq(qn, "exists") {
            return irg_codegen_exists(g, @e)
        }
        if str_eq(qn, "remove_file") {
            return irg_codegen_remove_file(g, @e)
        }
        if str_eq(qn, "system") {
            return irg_codegen_system(g, @e)
        }
        if qn.startswith("math.") {
            return irg_codegen_math(g, qn.slice(5, qn.len()), @e)
        }
        if str_eq(qn, "asyncio.run") {
            if e.args.len() == 1 {
                return irg_codegen_await_value(g, e.args.get(0))
            }
            return "0"
        }
        if str_eq(qn, "asyncio.gather") {
            return irg_codegen_gather_spawn(g, @e)
        }
        if str_eq(qn, "asyncio.wait_any") {
            return irg_codegen_asyncio_wait_any(g, @e)
        }
        if str_eq(qn, "asyncio.cancelled") {
            return irg_codegen_asyncio_cancelled(g)
        }
        if str_eq(qn, "time.now_monotonic") {
            return irg_codegen_now_monotonic(g, @e)
        }
        if str_eq(qn, "time.now") {
            return irg_codegen_now(g, @e)
        }
        if str_eq(qn, "time.sleep") {
            return irg_codegen_sleep(g, @e)
        }
        if str_eq(qn, "random.seed") {
            return irg_codegen_rand_seed(g, @e)
        }
        if str_eq(qn, "random.random_int") {
            return irg_codegen_rand_int(g, @e)
        }
        if str_eq(qn, "random.random_float") {
            return irg_codegen_rand_float(g, @e)
        }
        if str_eq(qn, "os.exit") {
            return irg_codegen_os_exit(g, @e)
        }
        if str_eq(qn, "os.getenv") {
            return irg_codegen_os_getenv(g, @e)
        }
        if str_eq(qn, "os.setenv") {
            return irg_codegen_os_setenv(g, @e)
        }
        if str_eq(qn, "os.getcwd") {
            return irg_codegen_os_getcwd(g, @e)
        }
        return irg_codegen_free_call(g, qn, @e)
    }
    # Generic enum construction: Maybe[int].Some(42) / Result[int,str].Ok(7)
    if e.object.len() > 0 and e.object.get(0).kind == ExprTypeApply() {
        ta = e.object.get(0)
        inst = mangled_of_type_apply(g, ta)
        irg_ensure_enum_layout(g, inst)
        irg_ensure_type(g, inst)
        bidx = irg_builtin_variant_idx(inst, e.name)
        if bidx >= 0 or (g.enum_variant_idx.contains(e.name) and
                         str_eq(g.enum_variant_enum.get(e.name), inst)) {
            return irg_enum_constructor(g, e, inst)
        }
        return "0"
    } elif e.name == "print" {
        irg_codegen_print(g, e)
        return "0"
    } elif e.name == "to_string" {
        return irg_codegen_to_string(g, e)
    } elif e.name == "chr" {
        return irg_codegen_chr(g, e)
    } elif e.name == "format" {
        return irg_codegen_format(g, e)
    } elif irg_is_math_builtin(e.name) and
            not g.fn_ret_kinds.contains(irg_call_target(g, @e)) {
        return irg_codegen_math(g, e.name, @e)
    } elif e.name == "args" {
        return irg_codegen_args(g)
    } elif e.name == "system" {
        return irg_codegen_system(g, @e)
    } elif e.name == "read_file" {
        return irg_codegen_read_file(g, @e)
    } elif e.name == "write_file" {
        return irg_codegen_write_file(g, @e)
    } elif e.name == "append_file" {
        return irg_codegen_append_file(g, @e)
    } elif e.name == "exists" {
        return irg_codegen_exists(g, @e)
    } elif e.name == "remove_file" {
        return irg_codegen_remove_file(g, @e)
    } elif e.name == "emit_object" {
        ir = irg_codegen_expr(g, e.args.get(0))
        path = irg_codegen_expr(g, e.args.get(1))
        er = irg_new_reg(g)
        irg_add(g, er + " = call i32 @rgc_emit_object(ptr " + ir + ", ptr " + path + ")")
        ex = irg_new_reg(g)
        irg_add(g, ex + " = sext i32 " + er + " to i64")
        return ex
    } elif e.name == "write_stderr" {
        data = irg_codegen_expr(g, e.args.get(0))
        slen = irg_new_reg(g)
        irg_add(g, slen + " = call i64 @strlen(ptr " + data + ")")
        wrr = irg_new_reg(g)
        irg_add(g, wrr + " = call i64 @write(i32 2, ptr " + data + ", i64 " + slen + ")")
        return "0"
    } elif e.name == "List" and e.type_args.len() == 1 {
        inst = irg_te_mangled(g, e.type_args.get(0))
        full = "List$" + inst
        irg_ensure_type(g, full)
        return irg_zero_struct(g, full)
    } elif e.name == "Map" and e.type_args.len() == 2 {
        k = irg_te_mangled(g, e.type_args.get(0))
        v = irg_te_mangled(g, e.type_args.get(1))
        full = "Map$" + k + "$" + v
        irg_ensure_type(g, full)
        return irg_zero_struct(g, full)
    } elif e.type_args.len() > 0 {
        full = irg_resolve_type_key(g, e.name)
        ti = 0
        while ti < e.type_args.len() {
            full = full + "$" + irg_te_mangled(g, e.type_args.get(ti))
            ti = ti + 1
        }
        if g.class_fields.contains(full) {
            irg_ensure_type(g, full)
            return irg_zero_struct(g, full)
        }
        return "0"
    } elif e.object.len() == 0 and g.enum_variant_idx.contains(e.name) {
        enum_name = g.enum_variant_enum.get(e.name)
        irg_ensure_enum_layout(g, enum_name)
        irg_ensure_type(g, enum_name)
        return irg_enum_constructor(g, e, enum_name)
    } elif e.object.len() == 0 and g.class_fields.contains(irg_resolve_type_key(g, e.name)) {
        full = irg_resolve_type_key(g, e.name)
        irg_ensure_type(g, full)
        return irg_zero_struct(g, full)
    } elif e.object.len() > 0 {
        return irg_codegen_method_call(g, e)
    } else {
        # Free-function calls: the symbol comes from Sema's resolution (call_syms); falls back to local derivation.
        fn_sym = irg_call_target(g, @e)
        return irg_codegen_free_call(g, fn_sym, @e)
    }
}

# Zero-value structs (List/Map/class construction).
public def irg_zero_struct(g: @var IRGen, name: str) -> str {
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + name)
    irg_add(g, "store %" + name + " zeroinitializer, ptr " + a)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + name + ", ptr " + a)
    return r
}

# Enum variant construction.
public def irg_enum_constructor(g: @var IRGen, e: Expr, enum_name: str) -> str {
    v_idx = irg_builtin_variant_idx(enum_name, e.name)
    if v_idx < 0 and g.enum_variant_idx.contains(e.name) {
        v_idx = g.enum_variant_idx.get(e.name)
    }
    kinds_all = g.enum_field_kinds.get(enum_name).split("|")
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + enum_name)
    disc_p = irg_new_reg(g)
    irg_add(g, disc_p + " = getelementptr %" + enum_name + ", ptr " + a +
              ", i32 0, i32 0")
    irg_add(g, "store i8 " + to_string(v_idx) + ", ptr " + disc_p)

    kinds = List[str]()
    if v_idx < kinds_all.len() {
        kinds = kinds_all.get(v_idx).split(",")
    }
    i = 0
    while i < e.args.len() and i < kinds.len() {
        v = irg_codegen_expr(g, e.args.get(i))
        k = kinds.get(i)
        slot_v = irg_payload_bits(g, k, v)
        slot_p = irg_new_reg(g)
        irg_add(g, slot_p + " = getelementptr %" + enum_name + ", ptr " + a +
                  ", i32 0, i32 1, i32 " + to_string(i))
        irg_add(g, "store i64 " + slot_v + ", ptr " + slot_p)
        i = i + 1
    }
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + enum_name + ", ptr " + a)
    return r
}

# print(...): a printf call.
public def irg_codegen_print(g: @var IRGen, e: Expr) {
    fmt = ""
    i = 0
    while i < e.args.len() {
        k = irg_expr_kind(g, e.args.get(i))
        if str_eq(k, "float") {
            fmt = fmt + "%f"
        } elif str_eq(k, "bool") {
            fmt = fmt + "%s"
        } elif str_eq(k, "str") {
            fmt = fmt + "%s"
        } else {
            fmt = fmt + "%lld"
        }
        if i + 1 < e.args.len() {
            fmt = fmt + " "
        }
        i = i + 1
    }
    fmt = fmt + "\n"
    fmt_ptr = irg_emit_string_const(g, fmt)

    args = ""
    i = 0
    while i < e.args.len() {
        k = irg_expr_kind(g, e.args.get(i))
        if str_eq(k, "bool") {
            v = irg_codegen_expr(g, e.args.get(i))
            ts = irg_emit_string_const(g, "True")
            fs = irg_emit_string_const(g, "False")
            s = irg_new_reg(g)
            irg_add(g, s + " = select i1 " + v + ", ptr " + ts + ", ptr " + fs)
            args = args + "ptr " + s
        } elif str_eq(k, "float") {
            v = irg_codegen_expr(g, e.args.get(i))
            args = args + "double " + v
        } elif str_eq(k, "str") {
            v = irg_codegen_expr(g, e.args.get(i))
            args = args + "ptr " + v
        } else {
            v = irg_codegen_expr(g, e.args.get(i))
            args = args + "i64 " + v
        }
        if i + 1 < e.args.len() {
            args = args + ", "
        }
        i = i + 1
    }
    pr = irg_new_reg(g)
    irg_add(g, pr + " = call i32 (ptr, ...) @printf(ptr " + fmt_ptr + ", " + args + ")")
}

# to_string(x).
public def irg_codegen_to_string(g: @var IRGen, e: Expr) -> str {
    return irg_value_to_string(g, e.args.get(0))
}

# chr(cp): encode a Unicode code point as UTF-8; invalid code points panic.
public def irg_codegen_chr(g: @var IRGen, e: Expr) -> str {
    cp = irg_codegen_expr(g, e.args.get(0))
    negc = irg_new_reg(g)
    irg_add(g, negc + " = icmp slt i64 " + cp + ", 0")
    big = irg_new_reg(g)
    irg_add(g, big + " = icmp sgt i64 " + cp + ", 1114111")
    sur_lo = irg_new_reg(g)
    irg_add(g, sur_lo + " = icmp sge i64 " + cp + ", 55296")
    sur_hi = irg_new_reg(g)
    irg_add(g, sur_hi + " = icmp sle i64 " + cp + ", 57343")
    sur = irg_new_reg(g)
    irg_add(g, sur + " = and i1 " + sur_lo + ", " + sur_hi)
    bad0 = irg_new_reg(g)
    irg_add(g, bad0 + " = or i1 " + negc + ", " + big)
    bad = irg_new_reg(g)
    irg_add(g, bad + " = or i1 " + bad0 + ", " + sur)
    ok_label = irg_new_label(g, "chr.ok")
    bad_label = irg_new_label(g, "chr.bad")
    irg_add(g, "br i1 " + bad + ", label %" + bad_label + ", label %" + ok_label)
    irg_add(g, bad_label + ":")
    msg = irg_emit_string_const(g, "panic: chr() code point out of range\n")
    pm = irg_new_reg(g)
    irg_add(g, pm + " = call i32 (ptr, ...) @printf(ptr " + msg + ")")
    irg_add(g, "call void @exit(i32 1)")
    irg_add(g, "unreachable")
    irg_add(g, ok_label + ":")

    r1 = irg_new_reg(g)
    irg_add(g, r1 + " = icmp ule i64 " + cp + ", 127")
    r2 = irg_new_reg(g)
    irg_add(g, r2 + " = icmp ule i64 " + cp + ", 2047")
    r3 = irg_new_reg(g)
    irg_add(g, r3 + " = icmp ule i64 " + cp + ", 65535")

    sh6 = irg_new_reg(g)
    irg_add(g, sh6 + " = lshr i64 " + cp + ", 6")
    sh12 = irg_new_reg(g)
    irg_add(g, sh12 + " = lshr i64 " + cp + ", 12")
    sh18 = irg_new_reg(g)
    irg_add(g, sh18 + " = lshr i64 " + cp + ", 18")
    low6 = irg_new_reg(g)
    irg_add(g, low6 + " = and i64 " + cp + ", 63")
    m6 = irg_new_reg(g)
    irg_add(g, m6 + " = and i64 " + sh6 + ", 63")
    m12 = irg_new_reg(g)
    irg_add(g, m12 + " = and i64 " + sh12 + ", 63")

    b0_2 = irg_new_reg(g)
    irg_add(g, b0_2 + " = or i64 " + sh6 + ", 192")
    b0_3 = irg_new_reg(g)
    irg_add(g, b0_3 + " = or i64 " + sh12 + ", 224")
    b0_4 = irg_new_reg(g)
    irg_add(g, b0_4 + " = or i64 " + sh18 + ", 240")
    b0_a = irg_new_reg(g)
    irg_add(g, b0_a + " = select i1 " + r2 + ", i64 " + b0_2 + ", i64 " + b0_3)
    b0_b = irg_new_reg(g)
    irg_add(g, b0_b + " = select i1 " + r3 + ", i64 " + b0_a + ", i64 " + b0_4)
    b0 = irg_new_reg(g)
    irg_add(g, b0 + " = select i1 " + r1 + ", i64 " + cp + ", i64 " + b0_b)

    b1_2 = irg_new_reg(g)
    irg_add(g, b1_2 + " = or i64 " + low6 + ", 128")
    b1_34 = irg_new_reg(g)
    irg_add(g, b1_34 + " = or i64 " + m6 + ", 128")
    b1_4 = irg_new_reg(g)
    irg_add(g, b1_4 + " = or i64 " + m12 + ", 128")
    b1_a = irg_new_reg(g)
    irg_add(g, b1_a + " = select i1 " + r2 + ", i64 " + b1_2 + ", i64 " + b1_34)
    b1 = irg_new_reg(g)
    irg_add(g, b1 + " = select i1 " + r3 + ", i64 " + b1_a + ", i64 " + b1_4)

    b2_3 = irg_new_reg(g)
    irg_add(g, b2_3 + " = or i64 " + low6 + ", 128")
    b2_4 = irg_new_reg(g)
    irg_add(g, b2_4 + " = or i64 " + m6 + ", 128")
    b2 = irg_new_reg(g)
    irg_add(g, b2 + " = select i1 " + r3 + ", i64 " + b2_3 + ", i64 " + b2_4)
    b3 = irg_new_reg(g)
    irg_add(g, b3 + " = or i64 " + low6 + ", 128")

    n2 = irg_new_reg(g)
    irg_add(g, n2 + " = select i1 " + r2 + ", i64 2, i64 3")
    n3 = irg_new_reg(g)
    irg_add(g, n3 + " = select i1 " + r3 + ", i64 " + n2 + ", i64 4")
    n = irg_new_reg(g)
    irg_add(g, n + " = select i1 " + r1 + ", i64 1, i64 " + n3)

    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 5)")
    t0 = irg_new_reg(g)
    irg_add(g, t0 + " = trunc i64 " + b0 + " to i8")
    irg_add(g, "store i8 " + t0 + ", ptr " + buf)
    p1 = irg_new_reg(g)
    irg_add(g, p1 + " = getelementptr i8, ptr " + buf + ", i64 1")
    t1 = irg_new_reg(g)
    irg_add(g, t1 + " = trunc i64 " + b1 + " to i8")
    irg_add(g, "store i8 " + t1 + ", ptr " + p1)
    p2 = irg_new_reg(g)
    irg_add(g, p2 + " = getelementptr i8, ptr " + buf + ", i64 2")
    t2 = irg_new_reg(g)
    irg_add(g, t2 + " = trunc i64 " + b2 + " to i8")
    irg_add(g, "store i8 " + t2 + ", ptr " + p2)
    p3 = irg_new_reg(g)
    irg_add(g, p3 + " = getelementptr i8, ptr " + buf + ", i64 3")
    t3 = irg_new_reg(g)
    irg_add(g, t3 + " = trunc i64 " + b3 + " to i8")
    irg_add(g, "store i8 " + t3 + ", ptr " + p3)
    pn = irg_new_reg(g)
    irg_add(g, pn + " = getelementptr i8, ptr " + buf + ", i64 " + n)
    irg_add(g, "store i8 0, ptr " + pn)
    return buf
}

# Scalar/string value -> string pointer (shared by to_string and format).
public def irg_value_to_string(g: @var IRGen, expr: Expr) -> str {
    k = irg_expr_kind_ref(g, @expr)
    v = irg_codegen_expr(g, expr)
    return irg_kind_to_string(g, v, k)
}

# Scalar/string value (already generated) -> string pointer.
public def irg_kind_to_string(g: @var IRGen, v: str, k: str) -> str {
    if str_eq(k, "str") {
        return v
    }
    if str_eq(k, "bool") {
        ts = irg_emit_string_const(g, "True")
        fs = irg_emit_string_const(g, "False")
        r = irg_new_reg(g)
        irg_add(g, r + " = select i1 " + v + ", ptr " + ts + ", ptr " + fs)
        return r
    }
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 64)")
    if str_eq(k, "float") {
        fmt = irg_emit_string_const(g, "%g")
        sn = irg_new_reg(g)
        irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
                  ", i64 64, ptr " + fmt + ", double " + v + ")")
    } else {
        fmt = irg_emit_string_const(g, "%lld")
        sn = irg_new_reg(g)
        irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
                  ", i64 64, ptr " + fmt + ", i64 " + v + ")")
    }
    return buf
}

# format(fmt, args...): fmt is a literal; each placeholder is replaced by an argument.
# `{{` / `}}` produce literal braces; the text inside braces is a format spec
# (see sema_format_spec_parse) such as `08x`, `>10s`, `.2f`, or `^12`.
public def irg_codegen_format(g: @var IRGen, e: Expr) -> str {
    fmt = e.args.get(0).str_val
    part_text = List[str]()
    part_is_arg = List[int]()
    part_arg_idx = List[int]()
    part_spec = List[str]()
    seg = ""
    arg_n = 0
    i = 0
    while i < fmt.len() {
        c = fmt.char_at(i)
        if c == "{".char_at(0) {
            if i + 1 < fmt.len() and fmt.char_at(i + 1) == "{".char_at(0) {
                seg = seg + "{"
                i = i + 2
            } else {
                j = i + 1
                while j < fmt.len() and fmt.char_at(j) != "}".char_at(0) {
                    j = j + 1
                }
                if j >= fmt.len() {
                    seg = seg + "{"
                    i = i + 1
                } else {
                    if seg.len() > 0 {
                        part_text.push(seg)
                        part_is_arg.push(0)
                        part_arg_idx.push(0)
                        part_spec.push("")
                        seg = ""
                    }
                    part_text.push("")
                    part_is_arg.push(1)
                    part_arg_idx.push(arg_n)
                    part_spec.push(fmt.slice(i + 1, j))
                    arg_n = arg_n + 1
                    i = j + 1
                }
            }
        } elif c == "}".char_at(0) {
            if i + 1 < fmt.len() and fmt.char_at(i + 1) == "}".char_at(0) {
                seg = seg + "}"
                i = i + 2
            } else {
                seg = seg + "}"
                i = i + 1
            }
        } else {
            seg = seg + fmt.slice(i, i + 1)
            i = i + 1
        }
    }
    if seg.len() > 0 {
        part_text.push(seg)
        part_is_arg.push(0)
        part_arg_idx.push(0)
        part_spec.push("")
    }

    part_ptrs = List[str]()
    part_lens = List[str]()
    total = "0"
    k = 0
    while k < part_text.len() {
        p = ""
        if part_is_arg.get(k) == 1 {
            p = irg_format_value(g, e.args.get(part_arg_idx.get(k) + 1), part_spec.get(k))
        } else {
            p = irg_emit_string_const(g, part_text.get(k))
        }
        part_ptrs.push(p)
        ln = irg_new_reg(g)
        irg_add(g, ln + " = call i64 @strlen(ptr " + p + ")")
        part_lens.push(ln)
        tot = irg_new_reg(g)
        irg_add(g, tot + " = add i64 " + total + ", " + ln)
        total = tot
        k = k + 1
    }
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + total + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")
    pos = "0"
    k = 0
    while k < part_ptrs.len() {
        dst = irg_new_reg(g)
        irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + pos)
        mc = irg_new_reg(g)
        irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + part_ptrs.get(k) +
                  ", i64 " + part_lens.get(k) + ")")
        np = irg_new_reg(g)
        irg_add(g, np + " = add i64 " + pos + ", " + part_lens.get(k))
        pos = np
        k = k + 1
    }
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + pos)
    irg_add(g, "store i8 0, ptr " + nul)
    return buf
}

# Format one argument using its placeholder spec. Empty specs keep the old
# to_string behavior; the sema pass has already rejected invalid specs.
public def irg_format_value(g: @var IRGen, expr: Expr, spec: str) -> str {
    k = irg_expr_kind_ref(g, @expr)
    v = irg_codegen_expr(g, expr)
    if spec.len() == 0 {
        return irg_kind_to_string(g, v, k)
    }
    info = sema_format_spec_parse(spec, k)
    if not info.ok {
        return irg_kind_to_string(g, v, k)
    }
    if str_eq(k, "bool") {
        ts = irg_emit_string_const(g, "True")
        fs = irg_emit_string_const(g, "False")
        p = irg_new_reg(g)
        irg_add(g, p + " = select i1 " + v + ", ptr " + ts + ", ptr " + fs)
        return irg_format_text(g, p, spec, k)
    }
    if str_eq(k, "str") {
        return irg_format_text(g, v, spec, k)
    }
    if str_eq(k, "int") {
        if info.conv == 5 {
            return irg_format_binary(g, v, spec)
        }
        return irg_format_number(g, v, spec, "int")
    }
    return irg_format_number(g, v, spec, "float")
}

# Format a C string (str/bool) with width, precision and alignment.
public def irg_format_text(g: @var IRGen, p: str, spec: str, kind: str) -> str {
    info = sema_format_spec_parse(spec, kind)
    cur = p
    if info.precision >= 0 {
        fs = "%." + to_string(info.precision) + "s"
        fmtp = irg_emit_string_const(g, fs)
        alloc = info.precision + 1
        if info.width + 1 > alloc {
            alloc = info.width + 1
        }
        buf = irg_new_reg(g)
        irg_add(g, buf + " = call ptr @malloc(i64 " + to_string(alloc) + ")")
        sn = irg_new_reg(g)
        irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
                  ", i64 " + to_string(alloc) + ", ptr " + fmtp + ", ptr " + cur + ")")
        cur = buf
    }
    if info.align == 3 {
        return irg_pad_center(g, cur, info.width)
    }
    if info.width == 0 {
        return cur
    }
    fs = "%"
    if info.align == 0 or info.align == 1 {
        fs = fs + "-"
    }
    fs = fs + to_string(info.width) + "s"
    fmtp = irg_emit_string_const(g, fs)
    alloc = info.width + 1
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + to_string(alloc) + ")")
    sn = irg_new_reg(g)
    irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
              ", i64 " + to_string(alloc) + ", ptr " + fmtp + ", ptr " + cur + ")")
    return buf
}

# Format an int/float through snprintf; center alignment is applied afterwards.
public def irg_format_number(g: @var IRGen, v: str, spec: str, kind: str) -> str {
    info = sema_format_spec_parse(spec, kind)
    left = 0
    width = info.width
    zero = info.zero
    if info.align == 3 {
        width = 0
        zero = 0
    } elif info.align == 1 {
        left = 1
    }
    fs = sema_format_printf_parts(kind, info.conv, info.plus, info.alt, zero,
                                  width, info.precision, left)
    fmtp = irg_emit_string_const(g, fs)
    size = 64
    if str_eq(kind, "float") {
        # %f can expand a double to ~309 integer digits.
        size = 512
    }
    if width > 0 {
        size = size + width
    }
    if info.precision > 0 {
        size = size + info.precision
    }
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + to_string(size) + ")")
    sn = irg_new_reg(g)
    if str_eq(kind, "float") {
        irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
                  ", i64 " + to_string(size) + ", ptr " + fmtp + ", double " + v + ")")
    } else {
        irg_add(g, sn + " = call i32 (ptr, i64, ptr, ...) @snprintf(ptr " + buf +
                  ", i64 " + to_string(size) + ", ptr " + fmtp + ", i64 " + v + ")")
    }
    if info.align == 3 {
        return irg_pad_center(g, buf, info.width)
    }
    return buf
}

# Binary integer formatting: 64-bit two's complement, with optional 0b prefix,
# width, zero/space padding and alignment.
public def irg_format_binary(g: @var IRGen, v: str, spec: str) -> str {
    info = sema_format_spec_parse(spec, "int")
    db = irg_new_reg(g)
    irg_add(g, db + " = call ptr @malloc(i64 65)")
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 63, ptr " + i_a)
    pos_a = irg_new_reg(g)
    irg_add(g, pos_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + pos_a)
    started_a = irg_new_reg(g)
    irg_add(g, started_a + " = alloca i1")
    irg_add(g, "store i1 false, ptr " + started_a)

    c_label = irg_new_label(g, "fb.cond")
    body_label = irg_new_label(g, "fb.body")
    keep_label = irg_new_label(g, "fb.keep")
    next_label = irg_new_label(g, "fb.next")
    end_label = irg_new_label(g, "fb.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp sge i64 " + i + ", 0")
    irg_add(g, "br i1 " + more + ", label %" + body_label + ", label %" + end_label)
    irg_add(g, body_label + ":")
    sh = irg_new_reg(g)
    irg_add(g, sh + " = lshr i64 " + v + ", " + i)
    bit = irg_new_reg(g)
    irg_add(g, bit + " = and i64 " + sh + ", 1")
    is_one = irg_new_reg(g)
    irg_add(g, is_one + " = icmp eq i64 " + bit + ", 1")
    old = irg_new_reg(g)
    irg_add(g, old + " = load i1, ptr " + started_a)
    at_zero = irg_new_reg(g)
    irg_add(g, at_zero + " = icmp eq i64 " + i + ", 0")
    k1 = irg_new_reg(g)
    irg_add(g, k1 + " = or i1 " + old + ", " + is_one)
    keep = irg_new_reg(g)
    irg_add(g, keep + " = or i1 " + k1 + ", " + at_zero)
    irg_add(g, "br i1 " + keep + ", label %" + keep_label + ", label %" + next_label)
    irg_add(g, keep_label + ":")
    ch = irg_new_reg(g)
    irg_add(g, ch + " = select i1 " + is_one + ", i8 49, i8 48")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr i8, ptr " + db + ", i64 " + pos)
    irg_add(g, "store i8 " + ch + ", ptr " + ep)
    pos2 = irg_new_reg(g)
    irg_add(g, pos2 + " = add i64 " + pos + ", 1")
    irg_add(g, "store i64 " + pos2 + ", ptr " + pos_a)
    irg_add(g, "store i1 true, ptr " + started_a)
    irg_add(g, "br label %" + next_label)
    irg_add(g, next_label + ":")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = sub i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, end_label + ":")
    pos_f = irg_new_reg(g)
    irg_add(g, pos_f + " = load i64, ptr " + pos_a)
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + db + ", i64 " + pos_f)
    irg_add(g, "store i8 0, ptr " + nul)

    prefix_len = 0
    if info.alt == 1 {
        prefix_len = 2
    }
    body_len = irg_new_reg(g)
    irg_add(g, body_len + " = add i64 " + pos_f + ", " + to_string(prefix_len))
    width = info.width
    if width < 0 {
        width = 0
    }
    total = irg_new_reg(g)
    irg_add(g, total + " = select i1 " + irg_binary_wide(g, width, body_len) +
              ", i64 " + to_string(width) + ", i64 " + body_len)
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + total + ", 1")
    out = irg_new_reg(g)
    irg_add(g, out + " = call ptr @malloc(i64 " + alloc + ")")
    pad = irg_new_reg(g)
    irg_add(g, pad + " = sub i64 " + total + ", " + body_len)
    has_pad = irg_new_reg(g)
    irg_add(g, has_pad + " = icmp sgt i64 " + pad + ", 0")
    none_label = irg_new_label(g, "fb.nopad")
    pad_label = irg_new_label(g, "fb.pad")
    done_label = irg_new_label(g, "fb.done")
    irg_add(g, "br i1 " + has_pad + ", label %" + pad_label + ", label %" + none_label)

    irg_add(g, none_label + ":")
    irg_binary_copy(g, out, "0", db, pos_f, prefix_len)
    irg_add(g, "br label %" + done_label)

    irg_add(g, pad_label + ":")
    if info.zero == 1 and info.align != 3 {
        if prefix_len > 0 {
            irg_add(g, "store i8 48, ptr " + out)
            p1 = irg_new_reg(g)
            irg_add(g, p1 + " = getelementptr i8, ptr " + out + ", i64 1")
            irg_add(g, "store i8 98, ptr " + p1)
        }
        zbase = irg_new_reg(g)
        irg_add(g, zbase + " = getelementptr i8, ptr " + out + ", i64 " + to_string(prefix_len))
        irg_fill_byte(g, zbase, pad, 48)
        dbase = irg_new_reg(g)
        irg_add(g, dbase + " = getelementptr i8, ptr " + zbase + ", i64 " + pad)
        mc = irg_new_reg(g)
        irg_add(g, mc + " = call ptr @memcpy(ptr " + dbase + ", ptr " + db + ", i64 " + pos_f + ")")
    } else {
        left = irg_binary_left_pad(g, pad, info.align)
        irg_fill_byte(g, out, left, 32)
        bbase = irg_new_reg(g)
        irg_add(g, bbase + " = getelementptr i8, ptr " + out + ", i64 " + left)
        irg_binary_copy(g, bbase, "0", db, pos_f, prefix_len)
        right = irg_new_reg(g)
        irg_add(g, right + " = sub i64 " + pad + ", " + left)
        rend = irg_new_reg(g)
        irg_add(g, rend + " = getelementptr i8, ptr " + bbase + ", i64 " + body_len)
        irg_fill_byte(g, rend, right, 32)
    }
    irg_add(g, "br label %" + done_label)

    irg_add(g, done_label + ":")
    tend = irg_new_reg(g)
    irg_add(g, tend + " = getelementptr i8, ptr " + out + ", i64 " + total)
    irg_add(g, "store i8 0, ptr " + tend)
    return out
}

def irg_binary_wide(g: @var IRGen, width: int, body_len: str) -> str {
    w = irg_new_reg(g)
    irg_add(g, w + " = icmp sgt i64 " + to_string(width) + ", " + body_len)
    return w
}

def irg_binary_left_pad(g: @var IRGen, pad: str, align: int) -> str {
    if align == 1 {
        return "0"
    }
    if align == 3 {
        l = irg_new_reg(g)
        irg_add(g, l + " = sdiv i64 " + pad + ", 2")
        return l
    }
    return pad
}

# Copy optional 0b prefix and binary digits at dst.
def irg_binary_copy(g: @var IRGen, dst: str, offset: str, digits: str, n: str, prefix_len: int) {
    p = irg_new_reg(g)
    irg_add(g, p + " = getelementptr i8, ptr " + dst + ", i64 " + offset)
    if prefix_len > 0 {
        irg_add(g, "store i8 48, ptr " + p)
        p1 = irg_new_reg(g)
        irg_add(g, p1 + " = getelementptr i8, ptr " + p + ", i64 1")
        irg_add(g, "store i8 98, ptr " + p1)
        d = irg_new_reg(g)
        irg_add(g, d + " = getelementptr i8, ptr " + p + ", i64 2")
        mc = irg_new_reg(g)
        irg_add(g, mc + " = call ptr @memcpy(ptr " + d + ", ptr " + digits + ", i64 " + n + ")")
    } else {
        mc = irg_new_reg(g)
        irg_add(g, mc + " = call ptr @memcpy(ptr " + p + ", ptr " + digits + ", i64 " + n + ")")
    }
}

# Fill `count` bytes at `p` with `byte`.
public def irg_fill_byte(g: @var IRGen, p: str, count: str, byte: int) {
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    c_label = irg_new_label(g, "fl.cond")
    b_label = irg_new_label(g, "fl.body")
    e_label = irg_new_label(g, "fl.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + count)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr i8, ptr " + p + ", i64 " + i)
    irg_add(g, "store i8 " + to_string(byte) + ", ptr " + ep)
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
}

# Center a C string in a field of `width` bytes (space padding).
public def irg_pad_center(g: @var IRGen, p: str, width: int) -> str {
    if width <= 0 {
        return p
    }
    ln = irg_new_reg(g)
    irg_add(g, ln + " = call i64 @strlen(ptr " + p + ")")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca ptr")
    irg_add(g, "store ptr " + p + ", ptr " + res_a)
    enough = irg_new_reg(g)
    irg_add(g, enough + " = icmp sge i64 " + ln + ", " + to_string(width))
    pad_label = irg_new_label(g, "ct.pad")
    end_label = irg_new_label(g, "ct.end")
    irg_add(g, "br i1 " + enough + ", label %" + end_label + ", label %" + pad_label)
    irg_add(g, pad_label + ":")
    pad_n = irg_new_reg(g)
    irg_add(g, pad_n + " = sub i64 " + to_string(width) + ", " + ln)
    left_n = irg_new_reg(g)
    irg_add(g, left_n + " = sdiv i64 " + pad_n + ", 2")
    right_n = irg_new_reg(g)
    irg_add(g, right_n + " = sub i64 " + pad_n + ", " + left_n)
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + to_string(width + 1) + ")")
    irg_fill_byte(g, buf, left_n, 32)
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + left_n)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + p + ", i64 " + ln + ")")
    rp = irg_new_reg(g)
    irg_add(g, rp + " = getelementptr i8, ptr " + dst + ", i64 " + ln)
    irg_fill_byte(g, rp, right_n, 32)
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + to_string(width))
    irg_add(g, "store i8 0, ptr " + nul)
    irg_add(g, "store ptr " + buf + ", ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load ptr, ptr " + res_a)
    return r
}

# args() -> List[str].
public def irg_codegen_args(g: @var IRGen) -> str {
    irg_ensure_type(g, "List$str")
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %List$str")
    irg_add(g, "store %List$str zeroinitializer, ptr " + a)
    argc = irg_new_reg(g)
    irg_add(g, argc + " = load i32, ptr @rgc.argc")
    argv = irg_new_reg(g)
    irg_add(g, argv + " = load ptr, ptr @rgc.argv")
    argc64 = irg_new_reg(g)
    irg_add(g, argc64 + " = zext i32 " + argc + " to i64")
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %List$str, ptr " + a + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr %List$str, ptr " + a + ", i32 0, i32 1")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr %List$str, ptr " + a + ", i32 0, i32 2")
    irg_add(g, "store ptr " + argv + ", ptr " + data_p)
    irg_add(g, "store i64 " + argc64 + ", ptr " + len_p)
    irg_add(g, "store i64 " + argc64 + ", ptr " + cap_p)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %List$str, ptr " + a)
    return r
}

# system(cmd): returns the real exit code.
public def irg_codegen_system(g: @var IRGen, e: @Expr) -> str {
    cmd = irg_codegen_expr(g, e.args.get(0))
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @system(ptr " + cmd + ")")
    sh = irg_new_reg(g)
    irg_add(g, sh + " = lshr i32 " + rc + ", 8")
    st = irg_new_reg(g)
    irg_add(g, st + " = and i32 " + sh + ", 255")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + st + " to i64")
    return r
}

# Conversion applied to enum payloads before writing them into an i64 slot.
public def irg_payload_bits(g: @var IRGen, kind: str, val: str) -> str {
    if str_eq(kind, "str") {
        r = irg_new_reg(g)
        irg_add(g, r + " = ptrtoint ptr " + val + " to i64")
        return r
    }
    if str_eq(kind, "float") {
        r = irg_new_reg(g)
        irg_add(g, r + " = bitcast double " + val + " to i64")
        return r
    }
    if str_eq(kind, "bool") {
        r = irg_new_reg(g)
        irg_add(g, r + " = zext i1 " + val + " to i64")
        return r
    }
    return val
}

# Construct a Result value.
public def irg_make_result(g: @var IRGen, result_name: str, is_ok: bool, payload: str) {
    irg_ensure_enum_layout(g, result_name)
    irg_ensure_type(g, result_name)
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + result_name)
    disc_p = irg_new_reg(g)
    irg_add(g, disc_p + " = getelementptr %" + result_name + ", ptr " + a +
              ", i32 0, i32 0")
    if is_ok {
        irg_add(g, "store i8 0, ptr " + disc_p)
    } else {
        irg_add(g, "store i8 1, ptr " + disc_p)
    }
    slot_p = irg_new_reg(g)
    irg_add(g, slot_p + " = getelementptr %" + result_name + ", ptr " + a +
              ", i32 0, i32 1, i32 0")
    kind = "int"
    if is_ok {
        ks = g.enum_field_kinds.get(result_name).split("|")
        if ks.len() > 0 {
            fs = ks.get(0).split(",")
            if fs.len() > 0 { kind = fs.get(0) }
        }
    } else {
        ks2 = g.enum_field_kinds.get(result_name).split("|")
        if ks2.len() > 1 {
            fs2 = ks2.get(1).split(",")
            if fs2.len() > 0 { kind = fs2.get(0) }
        }
    }
    bits = irg_payload_bits(g, kind, payload)
    irg_add(g, "store i64 " + bits + ", ptr " + slot_p)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + result_name + ", ptr " + a)
    irg_add(g, "ret %" + result_name + " " + r)
}

# read_file(path) -> Result[str, str].
public def irg_codegen_read_file(g: @var IRGen, e: @Expr) -> str {
    path = irg_codegen_expr(g, e.args.get(0))
    result_name = "Result$str$str"
    rb = irg_emit_string_const(g, "rb")
    file = irg_new_reg(g)
    irg_add(g, file + " = call ptr @fopen(ptr " + path + ", ptr " + rb + ")")
    fn = g.cur_fn
    ok_label = irg_new_label(g, "read.ok")
    fail_label = irg_new_label(g, "read.fail")
    merge_label = irg_new_label(g, "read.end")
    is_null = irg_new_reg(g)
    irg_add(g, is_null + " = icmp eq ptr " + file + ", null")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca %" + result_name)
    irg_add(g, "br i1 " + is_null + ", label %" + fail_label + ", label %" + ok_label)

    irg_add(g, fail_label + ":")
    irg_ensure_enum_layout(g, result_name)
    irg_ensure_type(g, result_name)
    fa = irg_new_reg(g)
    irg_add(g, fa + " = alloca %" + result_name)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 0")
    irg_add(g, "store i8 1, ptr " + fd)
    fp = irg_new_reg(g)
    irg_add(g, fp + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 1, i32 0")
    err_msg = irg_emit_string_const(g, "cannot open file")
    err_bits = irg_payload_bits(g, "str", err_msg)
    irg_add(g, "store i64 " + err_bits + ", ptr " + fp)
    fv = irg_new_reg(g)
    irg_add(g, fv + " = load %" + result_name + ", ptr " + fa)
    irg_add(g, "store %" + result_name + " " + fv + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, ok_label + ":")
    fs = irg_new_reg(g)
    irg_add(g, fs + " = call i32 @fseek(ptr " + file + ", i64 0, i32 2)")
    size = irg_new_reg(g)
    irg_add(g, size + " = call i64 @ftell(ptr " + file + ")")
    fs2 = irg_new_reg(g)
    irg_add(g, fs2 + " = call i32 @fseek(ptr " + file + ", i64 0, i32 0)")
    buf_size = irg_new_reg(g)
    irg_add(g, buf_size + " = add i64 " + size + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + buf_size + ")")
    fr = irg_new_reg(g)
    irg_add(g, fr + " = call i64 @fread(ptr " + buf + ", i64 1, i64 " + size + ", ptr " + file + ")")
    nul_p = irg_new_reg(g)
    irg_add(g, nul_p + " = getelementptr i8, ptr " + buf + ", i64 " + size)
    irg_add(g, "store i8 0, ptr " + nul_p)
    fc = irg_new_reg(g)
    irg_add(g, fc + " = call i32 @fclose(ptr " + file + ")")
    oa = irg_new_reg(g)
    irg_add(g, oa + " = alloca %" + result_name)
    od = irg_new_reg(g)
    irg_add(g, od + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 0")
    irg_add(g, "store i8 0, ptr " + od)
    op = irg_new_reg(g)
    irg_add(g, op + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 1, i32 0")
    buf_bits = irg_payload_bits(g, "str", buf)
    irg_add(g, "store i64 " + buf_bits + ", ptr " + op)
    ov = irg_new_reg(g)
    irg_add(g, ov + " = load %" + result_name + ", ptr " + oa)
    irg_add(g, "store %" + result_name + " " + ov + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, merge_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + result_name + ", ptr " + res_a)
    return r
}

# write_file(path, data) -> Result[None, str].
public def irg_codegen_write_file(g: @var IRGen, e: @Expr) -> str {
    return irg_codegen_write_file_mode(g, @e, "w", "write")
}

# append_file(path, data) -> Result[None, str].
public def irg_codegen_append_file(g: @var IRGen, e: @Expr) -> str {
    return irg_codegen_write_file_mode(g, @e, "a", "append")
}

public def irg_codegen_write_file_mode(g: @var IRGen, e: @Expr, mode: str, prefix: str) -> str {
    path = irg_codegen_expr(g, e.args.get(0))
    data = irg_codegen_expr(g, e.args.get(1))
    result_name = "Result$None$str"
    w = irg_emit_string_const(g, mode)
    file = irg_new_reg(g)
    irg_add(g, file + " = call ptr @fopen(ptr " + path + ", ptr " + w + ")")
    ok_label = irg_new_label(g, prefix + ".ok")
    fail_label = irg_new_label(g, prefix + ".fail")
    merge_label = irg_new_label(g, prefix + ".end")
    is_null = irg_new_reg(g)
    irg_add(g, is_null + " = icmp eq ptr " + file + ", null")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca %" + result_name)
    irg_add(g, "br i1 " + is_null + ", label %" + fail_label + ", label %" + ok_label)

    irg_add(g, fail_label + ":")
    irg_ensure_enum_layout(g, result_name)
    irg_ensure_type(g, result_name)
    fa = irg_new_reg(g)
    irg_add(g, fa + " = alloca %" + result_name)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 0")
    irg_add(g, "store i8 1, ptr " + fd)
    fp = irg_new_reg(g)
    irg_add(g, fp + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 1, i32 0")
    err_msg = irg_emit_string_const(g, "cannot open file")
    err_bits = irg_payload_bits(g, "str", err_msg)
    irg_add(g, "store i64 " + err_bits + ", ptr " + fp)
    fv = irg_new_reg(g)
    irg_add(g, fv + " = load %" + result_name + ", ptr " + fa)
    irg_add(g, "store %" + result_name + " " + fv + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, ok_label + ":")
    len = irg_new_reg(g)
    irg_add(g, len + " = call i64 @strlen(ptr " + data + ")")
    fw = irg_new_reg(g)
    irg_add(g, fw + " = call i64 @fwrite(ptr " + data + ", i64 1, i64 " + len + ", ptr " + file + ")")
    fc = irg_new_reg(g)
    irg_add(g, fc + " = call i32 @fclose(ptr " + file + ")")
    oa = irg_new_reg(g)
    irg_add(g, oa + " = alloca %" + result_name)
    od = irg_new_reg(g)
    irg_add(g, od + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 0")
    irg_add(g, "store i8 0, ptr " + od)
    op = irg_new_reg(g)
    irg_add(g, op + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 1, i32 0")
    irg_add(g, "store i64 0, ptr " + op)
    ov = irg_new_reg(g)
    irg_add(g, ov + " = load %" + result_name + ", ptr " + oa)
    irg_add(g, "store %" + result_name + " " + ov + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, merge_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + result_name + ", ptr " + res_a)
    return r
}

# exists(path) -> bool.
public def irg_codegen_exists(g: @var IRGen, e: @Expr) -> str {
    path = irg_codegen_expr(g, e.args.get(0))
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @access(ptr " + path + ", i32 0)")
    r = irg_new_reg(g)
    irg_add(g, r + " = icmp eq i32 " + rc + ", 0")
    return r
}

# remove_file(path) -> Result[None, str].
public def irg_codegen_remove_file(g: @var IRGen, e: @Expr) -> str {
    path = irg_codegen_expr(g, e.args.get(0))
    result_name = "Result$None$str"
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @remove(ptr " + path + ")")
    ok_label = irg_new_label(g, "remove.ok")
    fail_label = irg_new_label(g, "remove.fail")
    merge_label = irg_new_label(g, "remove.end")
    removed = irg_new_reg(g)
    irg_add(g, removed + " = icmp eq i32 " + rc + ", 0")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca %" + result_name)
    irg_add(g, "br i1 " + removed + ", label %" + ok_label + ", label %" + fail_label)

    irg_add(g, ok_label + ":")
    irg_ensure_enum_layout(g, result_name)
    irg_ensure_type(g, result_name)
    oa = irg_new_reg(g)
    irg_add(g, oa + " = alloca %" + result_name)
    od = irg_new_reg(g)
    irg_add(g, od + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 0")
    irg_add(g, "store i8 0, ptr " + od)
    op = irg_new_reg(g)
    irg_add(g, op + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 1, i32 0")
    irg_add(g, "store i64 0, ptr " + op)
    ov = irg_new_reg(g)
    irg_add(g, ov + " = load %" + result_name + ", ptr " + oa)
    irg_add(g, "store %" + result_name + " " + ov + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, fail_label + ":")
    fa = irg_new_reg(g)
    irg_add(g, fa + " = alloca %" + result_name)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 0")
    irg_add(g, "store i8 1, ptr " + fd)
    fp = irg_new_reg(g)
    irg_add(g, fp + " = getelementptr %" + result_name + ", ptr " + fa + ", i32 0, i32 1, i32 0")
    err_msg = irg_emit_string_const(g, "cannot remove file")
    err_bits = irg_payload_bits(g, "str", err_msg)
    irg_add(g, "store i64 " + err_bits + ", ptr " + fp)
    fv = irg_new_reg(g)
    irg_add(g, fv + " = load %" + result_name + ", ptr " + fa)
    irg_add(g, "store %" + result_name + " " + fv + ", ptr " + res_a)
    irg_add(g, "br label %" + merge_label)

    irg_add(g, merge_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + result_name + ", ptr " + res_a)
    return r
}

# time.now_monotonic() -> float (CLOCK_MONOTONIC seconds).
public def irg_codegen_now_monotonic(g: @var IRGen, e: @Expr) -> str {
    ts = irg_new_reg(g)
    irg_add(g, ts + " = alloca [2 x i64]")
    irg_add(g, "call i32 @clock_gettime(i32 1, ptr " + ts + ")")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 0")
    sec = irg_new_reg(g)
    irg_add(g, sec + " = load i64, ptr " + sp)
    np = irg_new_reg(g)
    irg_add(g, np + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 1")
    nsec = irg_new_reg(g)
    irg_add(g, nsec + " = load i64, ptr " + np)
    sf = irg_new_reg(g)
    irg_add(g, sf + " = sitofp i64 " + sec + " to double")
    nf = irg_new_reg(g)
    irg_add(g, nf + " = sitofp i64 " + nsec + " to double")
    frac = irg_new_reg(g)
    irg_add(g, frac + " = fdiv double " + nf + ", 1.0e9")
    r = irg_new_reg(g)
    irg_add(g, r + " = fadd double " + sf + ", " + frac)
    return r
}

# time.now() -> int (Unix timestamp seconds).
public def irg_codegen_now(g: @var IRGen, e: @Expr) -> str {
    r = irg_new_reg(g)
    irg_add(g, r + " = call i64 @time(ptr null)")
    return r
}

# time.sleep(seconds): truncate seconds to nanoseconds; negatives are treated as 0.
public def irg_codegen_sleep(g: @var IRGen, e: @Expr) -> str {
    a0 = e.args.get(0)
    k0 = irg_expr_kind_ref(g, @a0)
    v0 = irg_codegen_expr(g, a0)
    f0 = irg_math_to_f64(g, k0, v0)
    nsf = irg_new_reg(g)
    irg_add(g, nsf + " = fmul double " + f0 + ", 1.0e9")
    tot = irg_new_reg(g)
    irg_add(g, tot + " = fptosi double " + nsf + " to i64")
    neg = irg_new_reg(g)
    irg_add(g, neg + " = icmp sle i64 " + tot + ", 0")
    tot2 = irg_new_reg(g)
    irg_add(g, tot2 + " = select i1 " + neg + ", i64 0, i64 " + tot)
    sec = irg_new_reg(g)
    irg_add(g, sec + " = sdiv i64 " + tot2 + ", 1000000000")
    rem = irg_new_reg(g)
    irg_add(g, rem + " = srem i64 " + tot2 + ", 1000000000")
    ts = irg_new_reg(g)
    irg_add(g, ts + " = alloca [2 x i64]")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 0")
    irg_add(g, "store i64 " + sec + ", ptr " + sp)
    np = irg_new_reg(g)
    irg_add(g, np + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 1")
    irg_add(g, "store i64 " + rem + ", ptr " + np)
    irg_add(g, "call i32 @nanosleep(ptr " + ts + ", ptr null)")
    return "0"
}

# xorshift64: returns the new state.
public def irg_rand_next(g: @var IRGen) -> str {
    x = irg_new_reg(g)
    irg_add(g, x + " = load i64, ptr @rgc.rand_state")
    x1 = irg_new_reg(g)
    irg_add(g, x1 + " = shl i64 " + x + ", 13")
    x2 = irg_new_reg(g)
    irg_add(g, x2 + " = xor i64 " + x1 + ", " + x)
    x3 = irg_new_reg(g)
    irg_add(g, x3 + " = lshr i64 " + x2 + ", 7")
    x4 = irg_new_reg(g)
    irg_add(g, x4 + " = xor i64 " + x3 + ", " + x2)
    x5 = irg_new_reg(g)
    irg_add(g, x5 + " = shl i64 " + x4 + ", 17")
    x6 = irg_new_reg(g)
    irg_add(g, x6 + " = xor i64 " + x5 + ", " + x4)
    irg_add(g, "store i64 " + x6 + ", ptr @rgc.rand_state")
    return x6
}

# random.seed(x): sets the state to a non-zero value.
public def irg_codegen_rand_seed(g: @var IRGen, e: @Expr) -> str {
    v = irg_codegen_expr(g, e.args.get(0))
    s = irg_new_reg(g)
    irg_add(g, s + " = or i64 " + v + ", 1")
    irg_add(g, "store i64 " + s + ", ptr @rgc.rand_state")
    return "0"
}

# random.random_int(min, max): closed interval [min, max].
public def irg_codegen_rand_int(g: @var IRGen, e: @Expr) -> str {
    lo = irg_codegen_expr(g, e.args.get(0))
    hi = irg_codegen_expr(g, e.args.get(1))
    span = irg_new_reg(g)
    irg_add(g, span + " = sub i64 " + hi + ", " + lo)
    span1 = irg_new_reg(g)
    irg_add(g, span1 + " = add i64 " + span + ", 1")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = icmp sgt i64 " + span1 + ", 0")
    span2 = irg_new_reg(g)
    irg_add(g, span2 + " = select i1 " + pos + ", i64 " + span1 + ", i64 1")
    r = irg_rand_next(g)
    m = irg_new_reg(g)
    irg_add(g, m + " = urem i64 " + r + ", " + span2)
    res = irg_new_reg(g)
    irg_add(g, res + " = add i64 " + m + ", " + lo)
    return res
}

# random.random_float() -> [0, 1).
public def irg_codegen_rand_float(g: @var IRGen, e: @Expr) -> str {
    r = irg_rand_next(g)
    u = irg_new_reg(g)
    irg_add(g, u + " = lshr i64 " + r + ", 11")
    d = irg_new_reg(g)
    irg_add(g, d + " = uitofp i64 " + u + " to double")
    res = irg_new_reg(g)
    irg_add(g, res + " = fmul double " + d + ", 1.1102230246251565e-16")
    return res
}

# os.exit(code).
public def irg_codegen_os_exit(g: @var IRGen, e: @Expr) -> str {
    code = irg_codegen_expr(g, e.args.get(0))
    c32 = irg_new_reg(g)
    irg_add(g, c32 + " = trunc i64 " + code + " to i32")
    irg_add(g, "call void @exit(i32 " + c32 + ")")
    return "0"
}

# os.getenv(name) -> Maybe[str].
public def irg_codegen_os_getenv(g: @var IRGen, e: @Expr) -> str {
    name = irg_codegen_expr(g, e.args.get(0))
    val = irg_new_reg(g)
    irg_add(g, val + " = call ptr @getenv(ptr " + name + ")")
    enum_name = "Maybe$str"
    irg_ensure_enum_layout(g, enum_name)
    irg_ensure_type(g, enum_name)
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + enum_name)
    is_null = irg_new_reg(g)
    irg_add(g, is_null + " = icmp eq ptr " + val + ", null")
    disc = irg_new_reg(g)
    irg_add(g, disc + " = select i1 " + is_null + ", i8 1, i8 0")
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr %" + enum_name + ", ptr " + a + ", i32 0, i32 0")
    irg_add(g, "store i8 " + disc + ", ptr " + dp)
    bits = irg_new_reg(g)
    irg_add(g, bits + " = ptrtoint ptr " + val + " to i64")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr %" + enum_name + ", ptr " + a + ", i32 0, i32 1, i32 0")
    irg_add(g, "store i64 " + bits + ", ptr " + sp)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + enum_name + ", ptr " + a)
    return r
}

# os.setenv(name, value).
public def irg_codegen_os_setenv(g: @var IRGen, e: @Expr) -> str {
    name = irg_codegen_expr(g, e.args.get(0))
    val = irg_codegen_expr(g, e.args.get(1))
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @setenv(ptr " + name + ", ptr " + val + ", i32 1)")
    return "0"
}

# os.getcwd() -> Result[str, str] (getcwd(NULL, 0) allocates via libc).
public def irg_codegen_os_getcwd(g: @var IRGen, e: @Expr) -> str {
    result_name = "Result$str$str"
    irg_ensure_enum_layout(g, result_name)
    irg_ensure_type(g, result_name)
    val = irg_new_reg(g)
    irg_add(g, val + " = call ptr @getcwd(ptr null, i64 0)")
    is_null = irg_new_reg(g)
    irg_add(g, is_null + " = icmp eq ptr " + val + ", null")
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + result_name)
    disc = irg_new_reg(g)
    irg_add(g, disc + " = select i1 " + is_null + ", i8 1, i8 0")
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr %" + result_name + ", ptr " + a + ", i32 0, i32 0")
    irg_add(g, "store i8 " + disc + ", ptr " + dp)
    err_msg = irg_emit_string_const(g, "cannot get cwd")
    good_bits = irg_new_reg(g)
    irg_add(g, good_bits + " = ptrtoint ptr " + val + " to i64")
    err_bits = irg_new_reg(g)
    irg_add(g, err_bits + " = ptrtoint ptr " + err_msg + " to i64")
    bits = irg_new_reg(g)
    irg_add(g, bits + " = select i1 " + is_null + ", i64 " + err_bits + ", i64 " + good_bits)
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr %" + result_name + ", ptr " + a + ", i32 0, i32 1, i32 0")
    irg_add(g, "store i64 " + bits + ", ptr " + sp)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + result_name + ", ptr " + a)
    return r
}

# ---------------------------------------------------------------------------
# TCP primitives (wrapped by the standard library's net module)
#
# Conventions: addr/port are host-order integers; failure returns -1; tcp_error() retrieves the errno text.
# tcp_recv returns a heap-allocated C string ("" means EOF or error; errno is non-zero on error).
# ---------------------------------------------------------------------------

# Construct sockaddr_in on the stack (AF_INET, 16 bytes); family/port/addr are written in network byte order.
public def irg_tcp_sockaddr(g: @var IRGen, host: str, port: str) -> str {
    sa = irg_new_reg(g)
    irg_add(g, sa + " = alloca [16 x i8]")
    p0 = irg_new_reg(g)
    irg_add(g, p0 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 0")
    irg_add(g, "store i16 2, ptr " + p0)

    phi = irg_new_reg(g)
    irg_add(g, phi + " = lshr i64 " + port + ", 8")
    phb = irg_new_reg(g)
    irg_add(g, phb + " = trunc i64 " + phi + " to i8")
    p2 = irg_new_reg(g)
    irg_add(g, p2 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 2")
    irg_add(g, "store i8 " + phb + ", ptr " + p2)
    plb = irg_new_reg(g)
    irg_add(g, plb + " = trunc i64 " + port + " to i8")
    p3 = irg_new_reg(g)
    irg_add(g, p3 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 3")
    irg_add(g, "store i8 " + plb + ", ptr " + p3)

    s24 = irg_new_reg(g)
    irg_add(g, s24 + " = lshr i64 " + host + ", 24")
    a0 = irg_new_reg(g)
    irg_add(g, a0 + " = trunc i64 " + s24 + " to i8")
    p4 = irg_new_reg(g)
    irg_add(g, p4 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 4")
    irg_add(g, "store i8 " + a0 + ", ptr " + p4)

    s16 = irg_new_reg(g)
    irg_add(g, s16 + " = lshr i64 " + host + ", 16")
    a1 = irg_new_reg(g)
    irg_add(g, a1 + " = trunc i64 " + s16 + " to i8")
    p5 = irg_new_reg(g)
    irg_add(g, p5 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 5")
    irg_add(g, "store i8 " + a1 + ", ptr " + p5)

    s8 = irg_new_reg(g)
    irg_add(g, s8 + " = lshr i64 " + host + ", 8")
    a2 = irg_new_reg(g)
    irg_add(g, a2 + " = trunc i64 " + s8 + " to i8")
    p6 = irg_new_reg(g)
    irg_add(g, p6 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 6")
    irg_add(g, "store i8 " + a2 + ", ptr " + p6)

    a3 = irg_new_reg(g)
    irg_add(g, a3 + " = trunc i64 " + host + " to i8")
    p7 = irg_new_reg(g)
    irg_add(g, p7 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 7")
    irg_add(g, "store i8 " + a3 + ", ptr " + p7)

    p8 = irg_new_reg(g)
    irg_add(g, p8 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 8")
    irg_add(g, "store i64 0, ptr " + p8)
    return sa
}

# tcp_connect(host, port) -> fd / -1.
public def irg_codegen_tcp_connect(g: @var IRGen, e: @Expr) -> str {
    host = irg_codegen_expr(g, e.args.get(0))
    port = irg_codegen_expr(g, e.args.get(1))
    sa = irg_tcp_sockaddr(g, host, port)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = call i32 @socket(i64 2, i64 1, i64 0)")
    fd64 = irg_new_reg(g)
    irg_add(g, fd64 + " = sext i32 " + fd + " to i64")
    bad = irg_new_reg(g)
    irg_add(g, bad + " = icmp slt i32 " + fd + ", 0")
    res = irg_new_reg(g)
    irg_add(g, res + " = alloca i64")
    ok_l = irg_new_label(g, "tcp.connect.ok")
    good_l = irg_new_label(g, "tcp.connect.good")
    close_l = irg_new_label(g, "tcp.connect.close")
    bad_l = irg_new_label(g, "tcp.connect.fail")
    done_l = irg_new_label(g, "tcp.connect.end")
    irg_add(g, "br i1 " + bad + ", label %" + bad_l + ", label %" + ok_l)

    irg_add(g, ok_l + ":")
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @connect(i64 " + fd64 + ", ptr " + sa + ", i64 16)")
    okc = irg_new_reg(g)
    irg_add(g, okc + " = icmp eq i32 " + rc + ", 0")
    irg_add(g, "br i1 " + okc + ", label %" + good_l + ", label %" + close_l)

    irg_add(g, good_l + ":")
    irg_add(g, "store i64 " + fd64 + ", ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, close_l + ":")
    irg_add(g, "call i32 @close(i64 " + fd64 + ")")
    irg_add(g, "store i64 -1, ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, bad_l + ":")
    irg_add(g, "store i64 -1, ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, done_l + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res)
    return r
}

# tcp_listen(host, port, backlog) -> fd / -1.
public def irg_codegen_tcp_listen(g: @var IRGen, e: @Expr) -> str {
    host = irg_codegen_expr(g, e.args.get(0))
    port = irg_codegen_expr(g, e.args.get(1))
    backlog = irg_codegen_expr(g, e.args.get(2))
    sa = irg_tcp_sockaddr(g, host, port)
    fd = irg_new_reg(g)
    irg_add(g, fd + " = call i32 @socket(i64 2, i64 1, i64 0)")
    fd64 = irg_new_reg(g)
    irg_add(g, fd64 + " = sext i32 " + fd + " to i64")
    bad = irg_new_reg(g)
    irg_add(g, bad + " = icmp slt i32 " + fd + ", 0")
    res = irg_new_reg(g)
    irg_add(g, res + " = alloca i64")
    opt = irg_new_reg(g)
    irg_add(g, opt + " = alloca i32")
    ok_l = irg_new_label(g, "tcp.listen.ok")
    bound_l = irg_new_label(g, "tcp.listen.bound")
    good_l = irg_new_label(g, "tcp.listen.good")
    close_l = irg_new_label(g, "tcp.listen.close")
    bad_l = irg_new_label(g, "tcp.listen.fail")
    done_l = irg_new_label(g, "tcp.listen.end")
    irg_add(g, "br i1 " + bad + ", label %" + bad_l + ", label %" + ok_l)

    irg_add(g, ok_l + ":")
    irg_add(g, "store i32 1, ptr " + opt)
    irg_add(g, "call i32 @setsockopt(i64 " + fd64 + ", i64 1, i64 2, ptr " + opt + ", i64 4)")
    brc = irg_new_reg(g)
    irg_add(g, brc + " = call i32 @bind(i64 " + fd64 + ", ptr " + sa + ", i64 16)")
    bok = irg_new_reg(g)
    irg_add(g, bok + " = icmp eq i32 " + brc + ", 0")
    irg_add(g, "br i1 " + bok + ", label %" + bound_l + ", label %" + close_l)

    irg_add(g, bound_l + ":")
    lrc = irg_new_reg(g)
    irg_add(g, lrc + " = call i32 @listen(i64 " + fd64 + ", i64 " + backlog + ")")
    lok = irg_new_reg(g)
    irg_add(g, lok + " = icmp eq i32 " + lrc + ", 0")
    irg_add(g, "br i1 " + lok + ", label %" + good_l + ", label %" + close_l)

    irg_add(g, good_l + ":")
    irg_add(g, "store i64 " + fd64 + ", ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, close_l + ":")
    irg_add(g, "call i32 @close(i64 " + fd64 + ")")
    irg_add(g, "store i64 -1, ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, bad_l + ":")
    irg_add(g, "store i64 -1, ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, done_l + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res)
    return r
}

# tcp_accept(fd) -> connection fd / -1.
public def irg_codegen_tcp_accept(g: @var IRGen, e: @Expr) -> str {
    fd64 = irg_codegen_expr(g, e.args.get(0))
    c = irg_new_reg(g)
    irg_add(g, c + " = call i32 @accept(i64 " + fd64 + ", ptr null, ptr null)")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + c + " to i64")
    return r
}

# tcp_send(fd, data) -> bytes sent / -1 (MSG_NOSIGNAL avoids SIGPIPE).
public def irg_codegen_tcp_send(g: @var IRGen, e: @Expr) -> str {
    fd64 = irg_codegen_expr(g, e.args.get(0))
    data = irg_codegen_expr(g, e.args.get(1))
    len = irg_new_reg(g)
    irg_add(g, len + " = call i64 @strlen(ptr " + data + ")")
    r32 = irg_new_reg(g)
    irg_add(g, r32 + " = call i32 @send(i64 " + fd64 + ", ptr " + data + ", i64 " + len +
                ", i64 16384)")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + r32 + " to i64")
    return r
}

# tcp_recv(fd, max) -> heap string (at most max bytes; EOF/error returns an empty string).
public def irg_codegen_tcp_recv(g: @var IRGen, e: @Expr) -> str {
    fd64 = irg_codegen_expr(g, e.args.get(0))
    max = irg_codegen_expr(g, e.args.get(1))
    size = irg_new_reg(g)
    irg_add(g, size + " = add i64 " + max + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + size + ")")
    ep = irg_new_reg(g)
    irg_add(g, ep + " = call ptr @__errno_location()")
    irg_add(g, "store i32 0, ptr " + ep)
    n32 = irg_new_reg(g)
    irg_add(g, n32 + " = call i32 @recv(i64 " + fd64 + ", ptr " + buf + ", i64 " + max +
                ", i64 0)")
    n = irg_new_reg(g)
    irg_add(g, n + " = sext i32 " + n32 + " to i64")
    neg = irg_new_reg(g)
    irg_add(g, neg + " = icmp slt i64 " + n + ", 0")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = select i1 " + neg + ", i64 0, i64 " + n)
    tp = irg_new_reg(g)
    irg_add(g, tp + " = getelementptr i8, ptr " + buf + ", i64 " + pos)
    irg_add(g, "store i8 0, ptr " + tp)
    return buf
}

# tcp_close(fd).
public def irg_codegen_tcp_close(g: @var IRGen, e: @Expr) -> str {
    fd64 = irg_codegen_expr(g, e.args.get(0))
    irg_add(g, "call i32 @close(i64 " + fd64 + ")")
    return "0"
}

# tcp_local_port(fd) -> local port (getsockname), -1 on failure.
public def irg_codegen_tcp_local_port(g: @var IRGen, e: @Expr) -> str {
    fd64 = irg_codegen_expr(g, e.args.get(0))
    sa = irg_new_reg(g)
    irg_add(g, sa + " = alloca [16 x i8]")
    lenp = irg_new_reg(g)
    irg_add(g, lenp + " = alloca i32")
    irg_add(g, "store i32 16, ptr " + lenp)
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @getsockname(i64 " + fd64 + ", ptr " + sa + ", ptr " + lenp + ")")
    p2 = irg_new_reg(g)
    irg_add(g, p2 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 2")
    b0 = irg_new_reg(g)
    irg_add(g, b0 + " = load i8, ptr " + p2)
    z0 = irg_new_reg(g)
    irg_add(g, z0 + " = zext i8 " + b0 + " to i64")
    h = irg_new_reg(g)
    irg_add(g, h + " = shl i64 " + z0 + ", 8")
    p3 = irg_new_reg(g)
    irg_add(g, p3 + " = getelementptr [16 x i8], ptr " + sa + ", i32 0, i32 3")
    b1 = irg_new_reg(g)
    irg_add(g, b1 + " = load i8, ptr " + p3)
    z1 = irg_new_reg(g)
    irg_add(g, z1 + " = zext i8 " + b1 + " to i64")
    port = irg_new_reg(g)
    irg_add(g, port + " = or i64 " + h + ", " + z1)
    okc = irg_new_reg(g)
    irg_add(g, okc + " = icmp sge i32 " + rc + ", 0")
    r = irg_new_reg(g)
    irg_add(g, r + " = select i1 " + okc + ", i64 " + port + ", i64 -1")
    return r
}

# tcp_resolve(host) -> host-order IPv4 integer / -1 (gethostbyname; supports dotted-quad and hostnames).
public def irg_codegen_tcp_resolve(g: @var IRGen, e: @Expr) -> str {
    host = irg_codegen_expr(g, e.args.get(0))
    ep = irg_new_reg(g)
    irg_add(g, ep + " = call ptr @__errno_location()")
    irg_add(g, "store i32 0, ptr " + ep)
    he = irg_new_reg(g)
    irg_add(g, he + " = call ptr @gethostbyname(ptr " + host + ")")
    res = irg_new_reg(g)
    irg_add(g, res + " = alloca i64")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + he + ", null")
    ok_l = irg_new_label(g, "tcp.resolve.ok")
    list_l = irg_new_label(g, "tcp.resolve.list")
    fail_l = irg_new_label(g, "tcp.resolve.fail")
    done_l = irg_new_label(g, "tcp.resolve.end")
    irg_add(g, "br i1 " + isnull + ", label %" + fail_l + ", label %" + ok_l)

    irg_add(g, ok_l + ":")
    gap = irg_new_reg(g)
    irg_add(g, gap + " = getelementptr i8, ptr " + he + ", i64 24")
    list = irg_new_reg(g)
    irg_add(g, list + " = load ptr, ptr " + gap)
    lnull = irg_new_reg(g)
    irg_add(g, lnull + " = icmp eq ptr " + list + ", null")
    irg_add(g, "br i1 " + lnull + ", label %" + fail_l + ", label %" + list_l)

    irg_add(g, list_l + ":")
    ap = irg_new_reg(g)
    irg_add(g, ap + " = load ptr, ptr " + list)
    q0 = irg_new_reg(g)
    irg_add(g, q0 + " = getelementptr i8, ptr " + ap + ", i64 0")
    c0 = irg_new_reg(g)
    irg_add(g, c0 + " = load i8, ptr " + q0)
    z0 = irg_new_reg(g)
    irg_add(g, z0 + " = zext i8 " + c0 + " to i64")
    h0 = irg_new_reg(g)
    irg_add(g, h0 + " = shl i64 " + z0 + ", 24")
    q1 = irg_new_reg(g)
    irg_add(g, q1 + " = getelementptr i8, ptr " + ap + ", i64 1")
    c1 = irg_new_reg(g)
    irg_add(g, c1 + " = load i8, ptr " + q1)
    z1 = irg_new_reg(g)
    irg_add(g, z1 + " = zext i8 " + c1 + " to i64")
    h1 = irg_new_reg(g)
    irg_add(g, h1 + " = shl i64 " + z1 + ", 16")
    q2 = irg_new_reg(g)
    irg_add(g, q2 + " = getelementptr i8, ptr " + ap + ", i64 2")
    c2 = irg_new_reg(g)
    irg_add(g, c2 + " = load i8, ptr " + q2)
    z2 = irg_new_reg(g)
    irg_add(g, z2 + " = zext i8 " + c2 + " to i64")
    h2 = irg_new_reg(g)
    irg_add(g, h2 + " = shl i64 " + z2 + ", 8")
    q3 = irg_new_reg(g)
    irg_add(g, q3 + " = getelementptr i8, ptr " + ap + ", i64 3")
    c3 = irg_new_reg(g)
    irg_add(g, c3 + " = load i8, ptr " + q3)
    z3 = irg_new_reg(g)
    irg_add(g, z3 + " = zext i8 " + c3 + " to i64")
    o0 = irg_new_reg(g)
    irg_add(g, o0 + " = or i64 " + h0 + ", " + h1)
    o1 = irg_new_reg(g)
    irg_add(g, o1 + " = or i64 " + o0 + ", " + h2)
    addr = irg_new_reg(g)
    irg_add(g, addr + " = or i64 " + o1 + ", " + z3)
    irg_add(g, "store i64 " + addr + ", ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, fail_l + ":")
    irg_add(g, "store i64 -1, ptr " + res)
    irg_add(g, "br label %" + done_l)

    irg_add(g, done_l + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res)
    return r
}

# tcp_error() -> strerror(errno); returns an empty string when errno is 0.
public def irg_codegen_tcp_error(g: @var IRGen, e: @Expr) -> str {
    ep = irg_new_reg(g)
    irg_add(g, ep + " = call ptr @__errno_location()")
    code = irg_new_reg(g)
    irg_add(g, code + " = load i32, ptr " + ep)
    code64 = irg_new_reg(g)
    irg_add(g, code64 + " = sext i32 " + code + " to i64")
    msg = irg_new_reg(g)
    irg_add(g, msg + " = call ptr @strerror(i64 " + code64 + ")")
    zero = irg_new_reg(g)
    irg_add(g, zero + " = icmp eq i32 " + code + ", 0")
    empty = irg_emit_string_const(g, "")
    r = irg_new_reg(g)
    irg_add(g, r + " = select i1 " + zero + ", ptr " + empty + ", ptr " + msg)
    return r
}

# tcp_connect_fd(fd, sa, len) -> 0 / -1 (the error code stays in errno).
# Connect directly to a sockaddr returned by getaddrinfo; supports IPv4/IPv6/Unix.
public def irg_codegen_tcp_connect_fd(g: @var IRGen, e: @Expr) -> str {
    fd = irg_codegen_expr(g, e.args.get(0))
    sa = irg_codegen_expr(g, e.args.get(1))
    ln = irg_codegen_expr(g, e.args.get(2))
    r32 = irg_new_reg(g)
    irg_add(g, r32 + " = call i32 @connect(i64 " + fd + ", ptr " + sa + ", i64 " + ln + ")")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + r32 + " to i64")
    return r
}

public def irg_codegen_tcp_bind_fd(g: @var IRGen, e: @Expr) -> str {
    fd = irg_codegen_expr(g, e.args.get(0))
    sa = irg_codegen_expr(g, e.args.get(1))
    ln = irg_codegen_expr(g, e.args.get(2))
    r32 = irg_new_reg(g)
    irg_add(g, r32 + " = call i32 @bind(i64 " + fd + ", ptr " + sa + ", i64 " + ln + ")")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + r32 + " to i64")
    return r
}

public def irg_codegen_tcp_listen_fd(g: @var IRGen, e: @Expr) -> str {
    fd = irg_codegen_expr(g, e.args.get(0))
    backlog = irg_codegen_expr(g, e.args.get(1))
    r32 = irg_new_reg(g)
    irg_add(g, r32 + " = call i32 @listen(i64 " + fd + ", i64 " + backlog + ")")
    r = irg_new_reg(g)
    irg_add(g, r + " = sext i32 " + r32 + " to i64")
    return r
}

# ---------------------------------------------------------------------------
# Byte buffers / raw-pointer builtins
# ---------------------------------------------------------------------------

# buf_alloc(n) -> heap buffer (n+1 bytes, so n=0 still yields a valid address).
public def irg_codegen_buf_alloc(g: @var IRGen, e: @Expr) -> str {
    n = irg_codegen_expr(g, e.args.get(0))
    size = irg_new_reg(g)
    irg_add(g, size + " = add i64 " + n + ", 1")
    r = irg_new_reg(g)
    irg_add(g, r + " = call ptr @malloc(i64 " + size + ")")
    return r
}

public def irg_codegen_buf_realloc(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    n = irg_codegen_expr(g, e.args.get(1))
    size = irg_new_reg(g)
    irg_add(g, size + " = add i64 " + n + ", 1")
    r = irg_new_reg(g)
    irg_add(g, r + " = call ptr @realloc(ptr " + p + ", i64 " + size + ")")
    return r
}

public def irg_codegen_buf_free(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    irg_add(g, "call void @free(ptr " + p + ")")
    return "0"
}

public def irg_codegen_buf_zero(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    n = irg_codegen_expr(g, e.args.get(1))
    irg_add(g, "call void @memset(ptr " + p + ", i32 0, i64 " + n + ")")
    return "0"
}

public def irg_codegen_buf_copy(g: @var IRGen, e: @Expr) -> str {
    dst = irg_codegen_expr(g, e.args.get(0))
    di = irg_codegen_expr(g, e.args.get(1))
    src = irg_codegen_expr(g, e.args.get(2))
    si = irg_codegen_expr(g, e.args.get(3))
    n = irg_codegen_expr(g, e.args.get(4))
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr i8, ptr " + dst + ", i64 " + di)
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr i8, ptr " + src + ", i64 " + si)
    r = irg_new_reg(g)
    irg_add(g, r + " = call ptr @memmove(ptr " + dp + ", ptr " + sp + ", i64 " + n + ")")
    return "0"
}

public def irg_codegen_buf_get8(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    b = irg_new_reg(g)
    irg_add(g, b + " = load i8, ptr " + q + ", align 1")
    r = irg_new_reg(g)
    irg_add(g, r + " = zext i8 " + b + " to i64")
    return r
}

public def irg_codegen_buf_set8(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    v = irg_codegen_expr(g, e.args.get(2))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    b = irg_new_reg(g)
    irg_add(g, b + " = trunc i64 " + v + " to i8")
    irg_add(g, "store i8 " + b + ", ptr " + q + ", align 1")
    return "0"
}

public def irg_codegen_buf_get32(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    v = irg_new_reg(g)
    irg_add(g, v + " = load i32, ptr " + q + ", align 1")
    r = irg_new_reg(g)
    irg_add(g, r + " = zext i32 " + v + " to i64")
    return r
}

public def irg_codegen_buf_set32(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    v = irg_codegen_expr(g, e.args.get(2))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    b = irg_new_reg(g)
    irg_add(g, b + " = trunc i64 " + v + " to i32")
    irg_add(g, "store i32 " + b + ", ptr " + q + ", align 1")
    return "0"
}

public def irg_codegen_buf_get64(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + q + ", align 1")
    return r
}

public def irg_codegen_buf_set64(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    off = irg_codegen_expr(g, e.args.get(1))
    v = irg_codegen_expr(g, e.args.get(2))
    q = irg_new_reg(g)
    irg_add(g, q + " = getelementptr i8, ptr " + p + ", i64 " + off)
    irg_add(g, "store i64 " + v + ", ptr " + q + ", align 1")
    return "0"
}

# buf_to_str(p, n) -> copy n bytes and append NUL as a C string.
public def irg_codegen_buf_to_str(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    n = irg_codegen_expr(g, e.args.get(1))
    size = irg_new_reg(g)
    irg_add(g, size + " = add i64 " + n + ", 1")
    dst = irg_new_reg(g)
    irg_add(g, dst + " = call ptr @malloc(i64 " + size + ")")
    cp = irg_new_reg(g)
    irg_add(g, cp + " = call ptr @memcpy(ptr " + dst + ", ptr " + p + ", i64 " + n + ")")
    endp = irg_new_reg(g)
    irg_add(g, endp + " = getelementptr i8, ptr " + dst + ", i64 " + n)
    irg_add(g, "store i8 0, ptr " + endp + ", align 1")
    return dst
}

public def irg_codegen_ptr_null(g: @var IRGen, e: @Expr) -> str {
    return "null"
}

public def irg_codegen_ptr_is_null(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    r = irg_new_reg(g)
    irg_add(g, r + " = icmp eq ptr " + p + ", null")
    return r
}

public def irg_codegen_ptr_to_int(g: @var IRGen, e: @Expr) -> str {
    p = irg_codegen_expr(g, e.args.get(0))
    r = irg_new_reg(g)
    irg_add(g, r + " = ptrtoint ptr " + p + " to i64")
    return r
}

public def irg_codegen_int_to_ptr(g: @var IRGen, e: @Expr) -> str {
    v = irg_codegen_expr(g, e.args.get(0))
    r = irg_new_reg(g)
    irg_add(g, r + " = inttoptr i64 " + v + " to ptr")
    return r
}

# Method call dispatch.
public def irg_codegen_method_call(g: @var IRGen, e: Expr) -> str {
    obj_kind = irg_expr_kind(g, e.object.get(0))
    obj_custom = irg_expr_type_name(g, e.object.get(0))

    if str_eq(obj_kind, "str") {
        return irg_codegen_str_method(g, e)
    } elif obj_custom.startswith("List$") {
        return irg_codegen_list_method(g, e)
    } elif obj_custom.startswith("Map$") {
        return irg_codegen_map_method(g, e)
    } elif obj_custom.startswith("Task$") {
        return irg_codegen_task_method(g, e)
    } elif obj_custom.startswith("Maybe$") or obj_custom.startswith("Result$") {
        return irg_codegen_maybe_result_method(g, e)
    } else {
        # user class methods.
        fn = obj_custom + "$" + e.name
        if g.fn_ret_kinds.contains(fn) {
            obj_ptr = irg_object_ptr(g, e.object.get(0))
            if obj_ptr.len() == 0 {
                v = irg_codegen_expr(g, e.object.get(0))
                obj_ptr = irg_materialize_ptr(g, e.object.get(0), v, obj_custom)
            }
            return irg_emit_call(g, fn, obj_ptr, e, 1)
        }
        return "0"
    }
}

# Emit a function call: the first argument is the self pointer (has_self=1).
public def irg_emit_call(g: @var IRGen, fn: str, self_ptr: str, e: Expr, has_self: int) -> str {
    ret_ty = g.fn_ret_llvm_map.get(fn)
    params = g.fn_params_llvm.get(fn)
    kinds = g.fn_param_kinds.get(fn)
    customs = g.fn_param_customs.get(fn)
    arg_str = ""
    first = True
    if has_self == 1 {
        arg_str = "ptr " + self_ptr
        first = False
    }
    # parameter type list (skipping self).
    plist = List[str]()
    klist = List[str]()
    clist = List[str]()
    if params.len() > 0 {
        plist = params.split(",")
    }
    if kinds.len() > 0 {
        klist = kinds.split(",")
    }
    if customs.len() > 0 {
        clist = customs.split(",")
    }
    i = 0
    while i < e.args.len() and i + has_self < plist.len() {
        pi = i + has_self
        is_borrow_arg = False
        if pi < clist.len() and clist.get(pi).startswith("@") {
            is_borrow_arg = True
        }
        v = ""
        if is_borrow_arg {
            # borrow arguments: pass the variable's address (object pointer).
            v = irg_object_ptr(g, e.args.get(i))
            if v.len() == 0 {
                ev = irg_codegen_expr(g, e.args.get(i))
                kk = irg_expr_kind(g, e.args.get(i))
                cc = irg_expr_type_name(g, e.args.get(i))
                v = irg_materialize_ptr(g, e.args.get(i), ev, cc)
            }
        } else {
            v = irg_codegen_expr(g, e.args.get(i))
        }
        ty = ""
        if pi < plist.len() {
            pty = plist.get(pi)
            k = "int"
            if pi < klist.len() {
                k = klist.get(pi)
            }
            if str_eq(k, "custom") and not is_borrow_arg {
                v = irg_copy_class_value(g, e.args.get(i), v)
            }
            if str_eq(k, "float") {
                # int -> float promotion.
                kk = irg_expr_kind(g, e.args.get(i))
                if not str_eq(kk, "float") {
                    cv = irg_new_reg(g)
                    irg_add(g, cv + " = sitofp i64 " + v + " to double")
                    v = cv
                }
            }
            ty = pty
        }
        if not first {
            arg_str = arg_str + ", "
        }
        arg_str = arg_str + ty + " " + v
        first = False
        i = i + 1
    }
    r = irg_new_reg(g)
    if str_eq(ret_ty, "void") {
        irg_add(g, "call void @" + fn + "(" + arg_str + ")")
        return "0"
    }
    irg_add(g, r + " = call " + ret_ty + " @" + fn + "(" + arg_str + ")")
    return r
}

# Free-function calls.
public def irg_codegen_free_call(g: @var IRGen, fn: str, e: @Expr) -> str {
    # async fn call sites: spawn a thread and return Task[T], not a synchronous call.
    if g.async_fns.contains(fn) {
        return irg_codegen_spawn(g, fn, e)
    }
    if not g.fn_ret_kinds.contains(fn) {
        return "0"
    }

    # Builtin `str_to_float`: maps to libc `atof`.
    if str_eq(fn, "str_to_float") {
        s = irg_codegen_expr(g, e.args.get(0))
        r = irg_new_reg(g)
        irg_add(g, r + " = call double @atof(ptr " + s + ")")
        return r
    }

    # Builtin `emit_object`: calls the embedded LLVM shim.
    if str_eq(fn, "emit_object") {
        ir = irg_codegen_expr(g, e.args.get(0))
        path = irg_codegen_expr(g, e.args.get(1))
        er = irg_new_reg(g)
        irg_add(g, er + " = call i32 @rgc_emit_object(ptr " + ir + ", ptr " + path + ")")
        ex = irg_new_reg(g)
        irg_add(g, ex + " = sext i32 " + er + " to i64")
        return ex
    }

    # TCP primitives: generate libc socket calls directly.
    if str_eq(fn, "tcp_connect") {
        return irg_codegen_tcp_connect(g, e)
    }
    if str_eq(fn, "tcp_listen") {
        return irg_codegen_tcp_listen(g, e)
    }
    if str_eq(fn, "tcp_accept") {
        return irg_codegen_tcp_accept(g, e)
    }
    if str_eq(fn, "tcp_send") {
        return irg_codegen_tcp_send(g, e)
    }
    if str_eq(fn, "tcp_recv") {
        return irg_codegen_tcp_recv(g, e)
    }
    if str_eq(fn, "tcp_close") {
        return irg_codegen_tcp_close(g, e)
    }
    if str_eq(fn, "tcp_local_port") {
        return irg_codegen_tcp_local_port(g, e)
    }
    if str_eq(fn, "tcp_resolve") {
        return irg_codegen_tcp_resolve(g, e)
    }
    if str_eq(fn, "tcp_error") {
        return irg_codegen_tcp_error(g, e)
    }
    if str_eq(fn, "tcp_connect_fd") {
        return irg_codegen_tcp_connect_fd(g, e)
    }
    if str_eq(fn, "tcp_bind_fd") {
        return irg_codegen_tcp_bind_fd(g, e)
    }
    if str_eq(fn, "tcp_listen_fd") {
        return irg_codegen_tcp_listen_fd(g, e)
    }

    # Byte buffer / raw-pointer builtins.
    if str_eq(fn, "buf_alloc") {
        return irg_codegen_buf_alloc(g, e)
    }
    if str_eq(fn, "buf_realloc") {
        return irg_codegen_buf_realloc(g, e)
    }
    if str_eq(fn, "buf_free") {
        return irg_codegen_buf_free(g, e)
    }
    if str_eq(fn, "buf_zero") {
        return irg_codegen_buf_zero(g, e)
    }
    if str_eq(fn, "buf_copy") {
        return irg_codegen_buf_copy(g, e)
    }
    if str_eq(fn, "buf_get8") {
        return irg_codegen_buf_get8(g, e)
    }
    if str_eq(fn, "buf_set8") {
        return irg_codegen_buf_set8(g, e)
    }
    if str_eq(fn, "buf_get32") {
        return irg_codegen_buf_get32(g, e)
    }
    if str_eq(fn, "buf_set32") {
        return irg_codegen_buf_set32(g, e)
    }
    if str_eq(fn, "buf_get64") {
        return irg_codegen_buf_get64(g, e)
    }
    if str_eq(fn, "buf_set64") {
        return irg_codegen_buf_set64(g, e)
    }
    if str_eq(fn, "buf_to_str") {
        return irg_codegen_buf_to_str(g, e)
    }
    if str_eq(fn, "ptr_null") {
        return irg_codegen_ptr_null(g, e)
    }
    if str_eq(fn, "ptr_is_null") {
        return irg_codegen_ptr_is_null(g, e)
    }
    if str_eq(fn, "ptr_to_int") {
        return irg_codegen_ptr_to_int(g, e)
    }
    if str_eq(fn, "int_to_ptr") {
        return irg_codegen_int_to_ptr(g, e)
    }

    ret_ty = g.fn_ret_llvm_map.get(fn)
    params = g.fn_params_llvm.get(fn)
    kinds = g.fn_param_kinds.get(fn)
    customs = g.fn_param_customs.get(fn)
    is_extern = False
    if g.fn_is_extern.contains(fn) and g.fn_is_extern.get(fn) == 1 {
        is_extern = True
    }
    plist = List[str]()
    klist = List[str]()
    clist = List[str]()
    if params.len() > 0 {
        plist = params.split(",")
    }
    if kinds.len() > 0 {
        klist = kinds.split(",")
    }
    if customs.len() > 0 {
        clist = customs.split(",")
    }
    arg_str = ""
    i = 0
    while i < e.args.len() and i < plist.len() {
        is_borrow_arg = False
        if i < clist.len() and clist.get(i).startswith("@") {
            is_borrow_arg = True
        }
        v = ""
        if is_borrow_arg {
            v = irg_object_ptr(g, e.args.get(i))
            if v.len() == 0 {
                ev = irg_codegen_expr(g, e.args.get(i))
                kk = irg_expr_kind(g, e.args.get(i))
                cc = irg_expr_type_name(g, e.args.get(i))
                v = irg_materialize_ptr(g, e.args.get(i), ev, cc)
            }
        } else {
            v = irg_codegen_expr(g, e.args.get(i))
        }
        k = "int"
        if i < klist.len() {
            k = klist.get(i)
        }
        if str_eq(k, "custom") and not is_borrow_arg {
            v = irg_copy_class_value(g, e.args.get(i), v)
        }
        if str_eq(k, "float") {
            kk = irg_expr_kind(g, e.args.get(i))
            if not str_eq(kk, "float") {
                cv = irg_new_reg(g)
                irg_add(g, cv + " = sitofp i64 " + v + " to double")
                v = cv
            }
        }
        # extern C ABI: i1 boolean arguments are promoted to i8.
        if is_extern and str_eq(k, "bool") {
            zv = irg_new_reg(g)
            irg_add(g, zv + " = zext i1 " + v + " to i8")
            v = zv
        }
        if i > 0 {
            arg_str = arg_str + ", "
        }
        arg_str = arg_str + plist.get(i) + " " + v
        i = i + 1
    }
    r = irg_new_reg(g)
    if str_eq(ret_ty, "void") {
        irg_add(g, "call void @" + fn + "(" + arg_str + ")")
        return "0"
    }
    # extern C ABI return-value conversion: C int/bool are both i32 — int sexts back to i64,
    # bool converts back to i1 with icmp ne 0 (C truth semantics are "non-zero").
    if is_extern and str_eq(ret_ty, "i32") {
        irg_add(g, r + " = call i32 @" + fn + "(" + arg_str + ")")
        cv = irg_new_reg(g)
        if str_eq(g.fn_ret_kinds.get(fn), "bool") {
            irg_add(g, cv + " = icmp ne i32 " + r + ", 0")
        } else {
            irg_add(g, cv + " = sext i32 " + r + " to i64")
        }
        return cv
    }
    irg_add(g, r + " = call " + ret_ty + " @" + fn + "(" + arg_str + ")")
    return r
}

# ---------------------------------------------------------------------------
# async / Task
# ---------------------------------------------------------------------------

# Call an async fn: allocate a result box and argument block on the heap, run a wrapper function via pthread_create,
# and return Task[T] to the call site (the handle is the result-box pointer as an integer).
public def irg_codegen_spawn(g: @var IRGen, fn: str, e: @Expr) -> str {
    task = irg_task_type_of_fn(g, fn)
    if task.len() == 0 {
        return "0"
    }
    p = irg_task_payload_of(task)
    irg_ensure_task_box(g, task)
    irg_ensure_task_args(g, fn)
    if not g.async_wrappers.contains(fn) {
        g.async_wrappers.push(fn)
    }
    args_name = "TaskArgs$" + fn

    # argument block: field 0 is the result-box pointer; the arguments follow in order.
    szp = irg_new_reg(g)
    irg_add(g, szp + " = getelementptr %" + args_name + ", ptr null, i32 1")
    sz = irg_new_reg(g)
    irg_add(g, sz + " = ptrtoint ptr " + szp + " to i64")
    args = irg_new_reg(g)
    irg_add(g, args + " = call ptr @malloc(i64 " + sz + ")")

    bszp = irg_new_reg(g)
    irg_add(g, bszp + " = getelementptr %TaskBox$" + p + ", ptr null, i32 1")
    bsz = irg_new_reg(g)
    irg_add(g, bsz + " = ptrtoint ptr " + bszp + " to i64")
    box = irg_new_reg(g)
    irg_add(g, box + " = call ptr @malloc(i64 " + bsz + ")")
    donep0 = irg_new_reg(g)
    irg_add(g, donep0 + " = getelementptr %TaskBox$" + p + ", ptr " + box +
              ", i32 0, i32 1")
    irg_add(g, "store i64 0, ptr " + donep0)
    cancelp0 = irg_new_reg(g)
    irg_add(g, cancelp0 + " = getelementptr %TaskBox$" + p + ", ptr " + box +
              ", i32 0, i32 3")
    irg_add(g, "store i64 0, ptr " + cancelp0)

    bpp = irg_new_reg(g)
    irg_add(g, bpp + " = getelementptr %" + args_name + ", ptr " + args + ", i32 0, i32 0")
    irg_add(g, "store ptr " + box + ", ptr " + bpp)

    params = g.fn_params_llvm.get(fn)
    if params.len() > 0 {
        plist = params.split(",")
        i = 0
        while i < e.args.len() and i < plist.len() {
            v = irg_codegen_expr(g, e.args.get(i))
            ap = irg_new_reg(g)
            irg_add(g, ap + " = getelementptr %" + args_name + ", ptr " + args +
                      ", i32 0, i32 " + to_string(i + 1))
            irg_add(g, "store " + plist.get(i) + " " + v + ", ptr " + ap)
            i = i + 1
        }
    }

    # pthread_t is i64 on x86_64 glibc; write it directly into the result box's tid field.
    tidp = irg_new_reg(g)
    irg_add(g, tidp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 0")
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @pthread_create(ptr " + tidp + ", ptr null, ptr @" +
              fn + "$task, ptr " + args + ")")

    h = irg_new_reg(g)
    irg_add(g, h + " = ptrtoint ptr " + box + " to i64")
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + task)
    hp = irg_new_reg(g)
    irg_add(g, hp + " = getelementptr %" + task + ", ptr " + a + ", i32 0, i32 0")
    irg_add(g, "store i64 " + h + ", ptr " + hp)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + task + ", ptr " + a)
    return r
}

# Join an already-evaluated Task value. Inside a task thread, poll the child's
# done flag and forward the parent's cancellation request to the child; outside a
# task (asyncio.run from main), join directly. Then take out the payload and free
# the result box.
public def irg_join_task(g: @var IRGen, task: str, tv: str) -> str {
    p = irg_task_payload_of(task)
    if p.len() == 0 {
        return "0"
    }
    irg_ensure_task_box(g, task)
    pty = irg_task_payload_llvm(g, task)
    h = irg_new_reg(g)
    irg_add(g, h + " = extractvalue %" + task + " " + tv + ", 0")
    box = irg_new_reg(g)
    irg_add(g, box + " = inttoptr i64 " + h + " to ptr")
    tidp = irg_new_reg(g)
    irg_add(g, tidp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 0")
    tid = irg_new_reg(g)
    irg_add(g, tid + " = load i64, ptr " + tidp)
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 1")
    cp = irg_new_reg(g)
    irg_add(g, cp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 3")
    ts = irg_new_reg(g)
    irg_add(g, ts + " = alloca [2 x i64]")

    # Load the TLS pointer once; it is stable for the thread.
    parent_p = irg_new_reg(g)
    irg_add(g, parent_p + " = load ptr, ptr @rgc.tls_cancel")
    has_parent = irg_new_reg(g)
    irg_add(g, has_parent + " = icmp ne ptr " + parent_p + ", null")
    poll_l = irg_new_label(g, "join.poll")
    check_p = irg_new_label(g, "join.parent")
    req_l = irg_new_label(g, "join.req")
    check_d = irg_new_label(g, "join.done")
    sleep_l = irg_new_label(g, "join.sleep")
    join_l = irg_new_label(g, "join.join")
    irg_add(g, "br i1 " + has_parent + ", label %" + poll_l + ", label %" + join_l)
    irg_add(g, poll_l + ":")
    pp = irg_new_reg(g)
    irg_add(g, pp + " = load ptr, ptr @rgc.tls_cancel")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + pp + ", null")
    irg_add(g, "br i1 " + isnull + ", label %" + join_l + ", label %" + check_p)
    irg_add(g, check_p + ":")
    pv = irg_new_reg(g)
    irg_add(g, pv + " = load atomic i64, ptr " + pp + " monotonic, align 8")
    pset = irg_new_reg(g)
    irg_add(g, pset + " = icmp ne i64 " + pv + ", 0")
    irg_add(g, "br i1 " + pset + ", label %" + req_l + ", label %" + check_d)
    irg_add(g, req_l + ":")
    irg_add(g, "store atomic i64 1, ptr " + cp + " monotonic, align 8")
    irg_add(g, "br label %" + check_d)
    irg_add(g, check_d + ":")
    d = irg_new_reg(g)
    irg_add(g, d + " = load atomic i64, ptr " + dp + " monotonic, align 8")
    done = irg_new_reg(g)
    irg_add(g, done + " = icmp ne i64 " + d + ", 0")
    irg_add(g, "br i1 " + done + ", label %" + join_l + ", label %" + sleep_l)
    irg_add(g, sleep_l + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 0")
    irg_add(g, "store i64 0, ptr " + sp)
    np = irg_new_reg(g)
    irg_add(g, np + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 1")
    irg_add(g, "store i64 1000000, ptr " + np)
    irg_add(g, "call i32 @nanosleep(ptr " + ts + ", ptr null)")
    irg_add(g, "br label %" + poll_l)
    irg_add(g, join_l + ":")
    jr = irg_new_reg(g)
    irg_add(g, jr + " = call i32 @pthread_join(i64 " + tid + ", ptr null)")
    raw = "0"
    if not str_eq(p, "None") {
        payp = irg_new_reg(g)
        irg_add(g, payp + " = getelementptr %TaskBox$" + p + ", ptr " + box +
                  ", i32 0, i32 2")
        raw = irg_new_reg(g)
        irg_add(g, raw + " = load " + pty + ", ptr " + payp)
    }
    irg_add(g, "call void @free(ptr " + box + ")")
    return raw
}

# Shared implementation of await / asyncio.run: join the thread, take out the payload and free the result box.
public def irg_codegen_await_value(g: @var IRGen, op: Expr) -> str {
    task = irg_expr_type_name_ref(g, @op)
    p = irg_task_payload_of(task)
    if p.len() == 0 {
        return "0"
    }
    tv = irg_codegen_expr(g, op)
    return irg_join_task(g, task, tv)
}

# Thread entry: take the result box and arguments from the argument block, call the async function synchronously and write back the payload.
# Emitted after all functions (in_fn = 0, no debug metadata attached).
public def irg_emit_async_wrapper(g: @var IRGen, fn: str) {
    task = irg_task_type_of_fn(g, fn)
    if task.len() == 0 {
        return
    }
    p = irg_task_payload_of(task)
    irg_ensure_task_box(g, task)
    irg_ensure_task_args(g, fn)
    ret_ty = g.fn_ret_llvm_map.get(fn)
    args_name = "TaskArgs$" + fn

    g.reg = 0
    g.label = 0
    g.in_fn = 0
    irg_add(g, "define void @" + fn + "$task(ptr %args) {")
    irg_add(g, "entry:")
    bpp = irg_new_reg(g)
    irg_add(g, bpp + " = getelementptr %" + args_name + ", ptr %args, i32 0, i32 0")
    box = irg_new_reg(g)
    irg_add(g, box + " = load ptr, ptr " + bpp)
    # Record the cancellation-flag address of the current thread's Task, for asyncio.cancelled() to query.
    cancelp = irg_new_reg(g)
    irg_add(g, cancelp + " = getelementptr %TaskBox$" + p + ", ptr " + box +
              ", i32 0, i32 3")
    irg_add(g, "store ptr " + cancelp + ", ptr @rgc.tls_cancel")

    call_args = ""
    params = g.fn_params_llvm.get(fn)
    if params.len() > 0 {
        plist = params.split(",")
        i = 0
        while i < plist.len() {
            ap = irg_new_reg(g)
            irg_add(g, ap + " = getelementptr %" + args_name + ", ptr %args, i32 0, i32 " +
                      to_string(i + 1))
            v = irg_new_reg(g)
            irg_add(g, v + " = load " + plist.get(i) + ", ptr " + ap)
            if i > 0 {
                call_args = call_args + ", "
            }
            call_args = call_args + plist.get(i) + " " + v
            i = i + 1
        }
    }

    if str_eq(ret_ty, "void") {
        irg_add(g, "call void @" + fn + "(" + call_args + ")")
    } else {
        r = irg_new_reg(g)
        irg_add(g, r + " = call " + ret_ty + " @" + fn + "(" + call_args + ")")
        payp = irg_new_reg(g)
        irg_add(g, payp + " = getelementptr %TaskBox$" + p + ", ptr " + box +
                  ", i32 0, i32 2")
        irg_add(g, "store " + ret_ty + " " + r + ", ptr " + payp)
    }
    donep = irg_new_reg(g)
    irg_add(g, donep + " = getelementptr %TaskBox$" + p + ", ptr " + box +
              ", i32 0, i32 1")
    irg_add(g, "store atomic i64 1, ptr " + donep + " monotonic, align 8")
    irg_add(g, "call void @free(ptr %args)")
    irg_add(g, "ret void")
    irg_add(g, "}")
}

# asyncio.gather(tasks): spawn a join thread that waits for every task in the list and collects the payloads.
# Returns Task[List[T]], awaitable or bridged with asyncio.run.
public def irg_codegen_gather_spawn(g: @var IRGen, e: @Expr) -> str {
    if e.args.len() != 1 {
        return "0"
    }
    a0 = e.args.get(0)
    arg_ty = irg_expr_type_name_ref(g, @a0)
    if not arg_ty.startswith("List$Task$") {
        return "0"
    }
    elem_task = arg_ty.slice(5, arg_ty.len())
    p = irg_task_payload_of(elem_task)
    list_ty = "List$" + p
    task = "Task$" + list_ty
    irg_ensure_type(g, list_ty)
    irg_ensure_type(g, task)
    irg_ensure_task_box(g, task)
    irg_ensure_task_box(g, elem_task)
    irg_ensure_gather_args(g, p)
    if not g.gather_wrappers.contains(p) {
        g.gather_wrappers.push(p)
    }
    args_name = "GatherArgs$" + p

    szp = irg_new_reg(g)
    irg_add(g, szp + " = getelementptr %" + args_name + ", ptr null, i32 1")
    sz = irg_new_reg(g)
    irg_add(g, sz + " = ptrtoint ptr " + szp + " to i64")
    args = irg_new_reg(g)
    irg_add(g, args + " = call ptr @malloc(i64 " + sz + ")")

    bszp = irg_new_reg(g)
    irg_add(g, bszp + " = getelementptr %TaskBox$" + list_ty + ", ptr null, i32 1")
    bsz = irg_new_reg(g)
    irg_add(g, bsz + " = ptrtoint ptr " + bszp + " to i64")
    box = irg_new_reg(g)
    irg_add(g, box + " = call ptr @malloc(i64 " + bsz + ")")
    donep0 = irg_new_reg(g)
    irg_add(g, donep0 + " = getelementptr %TaskBox$" + list_ty + ", ptr " + box +
              ", i32 0, i32 1")
    irg_add(g, "store i64 0, ptr " + donep0)
    cancelp0 = irg_new_reg(g)
    irg_add(g, cancelp0 + " = getelementptr %TaskBox$" + list_ty + ", ptr " + box +
              ", i32 0, i32 3")
    irg_add(g, "store i64 0, ptr " + cancelp0)

    bpp = irg_new_reg(g)
    irg_add(g, bpp + " = getelementptr %" + args_name + ", ptr " + args + ", i32 0, i32 0")
    irg_add(g, "store ptr " + box + ", ptr " + bpp)

    tv = irg_codegen_expr(g, a0)
    in_a = irg_new_reg(g)
    irg_add(g, in_a + " = alloca %" + arg_ty)
    irg_add(g, "store %" + arg_ty + " " + tv + ", ptr " + in_a)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %" + arg_ty + ", ptr " + in_a + ", i32 0, i32 0")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr %" + arg_ty + ", ptr " + in_a + ", i32 0, i32 1")
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    ap1 = irg_new_reg(g)
    irg_add(g, ap1 + " = getelementptr %" + args_name + ", ptr " + args + ", i32 0, i32 1")
    irg_add(g, "store ptr " + data + ", ptr " + ap1)
    ap2 = irg_new_reg(g)
    irg_add(g, ap2 + " = getelementptr %" + args_name + ", ptr " + args + ", i32 0, i32 2")
    irg_add(g, "store i64 " + len + ", ptr " + ap2)

    tidp = irg_new_reg(g)
    irg_add(g, tidp + " = getelementptr %TaskBox$" + list_ty + ", ptr " + box +
              ", i32 0, i32 0")
    rc = irg_new_reg(g)
    irg_add(g, rc + " = call i32 @pthread_create(ptr " + tidp + ", ptr null, ptr @__rgc_gather$" +
              p + "$task, ptr " + args + ")")

    h = irg_new_reg(g)
    irg_add(g, h + " = ptrtoint ptr " + box + " to i64")
    a = irg_new_reg(g)
    irg_add(g, a + " = alloca %" + task)
    hp = irg_new_reg(g)
    irg_add(g, hp + " = getelementptr %" + task + ", ptr " + a + ", i32 0, i32 0")
    irg_add(g, "store i64 " + h + ", ptr " + hp)
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + task + ", ptr " + a)
    return r
}

# gather thread entry: join the input tasks one by one and push their payloads into the result list.
public def irg_emit_gather_wrapper(g: @var IRGen, p: str) {
    list_ty = "List$" + p
    task = "Task$" + list_ty
    elem_task = "Task$" + p
    irg_ensure_type(g, list_ty)
    irg_ensure_type(g, task)
    irg_ensure_type(g, elem_task)
    irg_ensure_task_box(g, task)
    irg_ensure_task_box(g, elem_task)
    irg_ensure_gather_args(g, p)
    args_name = "GatherArgs$" + p

    g.reg = 0
    g.label = 0
    g.in_fn = 0
    irg_add(g, "define void @__rgc_gather$" + p + "$task(ptr %args) {")
    irg_add(g, "entry:")
    bpp = irg_new_reg(g)
    irg_add(g, bpp + " = getelementptr %" + args_name + ", ptr %args, i32 0, i32 0")
    box = irg_new_reg(g)
    irg_add(g, box + " = load ptr, ptr " + bpp)
    datap = irg_new_reg(g)
    irg_add(g, datap + " = getelementptr %" + args_name + ", ptr %args, i32 0, i32 1")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + datap)
    lenp = irg_new_reg(g)
    irg_add(g, lenp + " = getelementptr %" + args_name + ", ptr %args, i32 0, i32 2")
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + lenp)

    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca %" + list_ty)
    irg_add(g, "store %" + list_ty + " zeroinitializer, ptr " + res_a)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)

    check_l = irg_new_label(g, "gather.check")
    body_l = irg_new_label(g, "gather.body")
    end_l = irg_new_label(g, "gather.end")
    irg_add(g, "br label %" + check_l)
    irg_add(g, check_l + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    cond = irg_new_reg(g)
    irg_add(g, cond + " = icmp slt i64 " + i + ", " + len)
    irg_add(g, "br i1 " + cond + ", label %" + body_l + ", label %" + end_l)
    irg_add(g, body_l + ":")
    tep = irg_new_reg(g)
    irg_add(g, tep + " = getelementptr %" + elem_task + ", ptr " + data + ", i64 " + i)
    tv = irg_new_reg(g)
    irg_add(g, tv + " = load %" + elem_task + ", ptr " + tep)
    payload = irg_join_task(g, elem_task, tv)
    irg_list_push(g, res_a, list_ty, p, payload)
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + check_l)
    irg_add(g, end_l + ":")

    res = irg_new_reg(g)
    irg_add(g, res + " = load %" + list_ty + ", ptr " + res_a)
    payp = irg_new_reg(g)
    irg_add(g, payp + " = getelementptr %TaskBox$" + list_ty + ", ptr " + box +
              ", i32 0, i32 2")
    irg_add(g, "store %" + list_ty + " " + res + ", ptr " + payp)
    donep = irg_new_reg(g)
    irg_add(g, donep + " = getelementptr %TaskBox$" + list_ty + ", ptr " + box +
              ", i32 0, i32 1")
    irg_add(g, "store atomic i64 1, ptr " + donep + " monotonic, align 8")
    irg_add(g, "call void @free(ptr %args)")
    irg_add(g, "ret void")
    irg_add(g, "}")
}

# asyncio.cancelled(): the cancellation-request flag of the current task's thread; returns false outside a task (empty TLS).
public def irg_codegen_asyncio_cancelled(g: @var IRGen) -> str {
    cp = irg_new_reg(g)
    irg_add(g, cp + " = load ptr, ptr @rgc.tls_cancel")
    out = irg_new_reg(g)
    irg_add(g, out + " = alloca i8")
    null_l = irg_new_label(g, "task.cancelled.none")
    task_l = irg_new_label(g, "task.cancelled.load")
    end_l = irg_new_label(g, "task.cancelled.end")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + cp + ", null")
    irg_add(g, "br i1 " + isnull + ", label %" + null_l + ", label %" + task_l)
    irg_add(g, null_l + ":")
    irg_add(g, "store i8 0, ptr " + out)
    irg_add(g, "br label %" + end_l)
    irg_add(g, task_l + ":")
    c = irg_new_reg(g)
    irg_add(g, c + " = load atomic i64, ptr " + cp + " monotonic, align 8")
    nz = irg_new_reg(g)
    irg_add(g, nz + " = icmp ne i64 " + c + ", 0")
    z = irg_new_reg(g)
    irg_add(g, z + " = zext i1 " + nz + " to i8")
    irg_add(g, "store i8 " + z + ", ptr " + out)
    irg_add(g, "br label %" + end_l)
    irg_add(g, end_l + ":")
    v = irg_new_reg(g)
    irg_add(g, v + " = load i8, ptr " + out)
    r = irg_new_reg(g)
    irg_add(g, r + " = icmp ne i8 " + v + ", 0")
    return r
}

# asyncio.wait_any(tasks): poll the done flags and return the index of the first completed task;
# an empty list returns -1 without consuming tasks (the caller then awaits/cancels each task).
public def irg_codegen_asyncio_wait_any(g: @var IRGen, e: @Expr) -> str {
    if e.args.len() != 1 {
        return "-1"
    }
    a0 = e.args.get(0)
    arg_ty = irg_expr_type_name_ref(g, @a0)
    if not arg_ty.startswith("List$Task$") {
        return "-1"
    }
    elem_task = arg_ty.slice(5, arg_ty.len())
    p = irg_task_payload_of(elem_task)
    irg_ensure_type(g, elem_task)
    irg_ensure_task_box(g, elem_task)

    tv = irg_codegen_expr(g, a0)
    in_a = irg_new_reg(g)
    irg_add(g, in_a + " = alloca %" + arg_ty)
    irg_add(g, "store %" + arg_ty + " " + tv + ", ptr " + in_a)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %" + arg_ty + ", ptr " + in_a + ", i32 0, i32 0")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr %" + arg_ty + ", ptr " + in_a + ", i32 0, i32 1")
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)

    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca i64")
    irg_add(g, "store i64 -1, ptr " + res_a)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    ts = irg_new_reg(g)
    irg_add(g, ts + " = alloca [2 x i64]")

    scan_l = irg_new_label(g, "wait_any.scan")
    check_l = irg_new_label(g, "wait_any.check")
    probe_l = irg_new_label(g, "wait_any.probe")
    next_l = irg_new_label(g, "wait_any.next")
    found_l = irg_new_label(g, "wait_any.found")
    sleep_l = irg_new_label(g, "wait_any.sleep")
    end_l = irg_new_label(g, "wait_any.end")
    empty = irg_new_reg(g)
    irg_add(g, empty + " = icmp sle i64 " + len + ", 0")
    irg_add(g, "br i1 " + empty + ", label %" + end_l + ", label %" + scan_l)
    irg_add(g, scan_l + ":")
    irg_add(g, "store i64 0, ptr " + i_a)
    irg_add(g, "br label %" + check_l)
    irg_add(g, check_l + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    cond = irg_new_reg(g)
    irg_add(g, cond + " = icmp slt i64 " + i + ", " + len)
    irg_add(g, "br i1 " + cond + ", label %" + probe_l + ", label %" + sleep_l)
    irg_add(g, probe_l + ":")
    tep = irg_new_reg(g)
    irg_add(g, tep + " = getelementptr %" + elem_task + ", ptr " + data + ", i64 " + i)
    tv2 = irg_new_reg(g)
    irg_add(g, tv2 + " = load %" + elem_task + ", ptr " + tep)
    h = irg_new_reg(g)
    irg_add(g, h + " = extractvalue %" + elem_task + " " + tv2 + ", 0")
    box = irg_new_reg(g)
    irg_add(g, box + " = inttoptr i64 " + h + " to ptr")
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 1")
    d = irg_new_reg(g)
    irg_add(g, d + " = load atomic i64, ptr " + dp + " monotonic, align 8")
    fin = irg_new_reg(g)
    irg_add(g, fin + " = icmp ne i64 " + d + ", 0")
    irg_add(g, "br i1 " + fin + ", label %" + found_l + ", label %" + next_l)
    irg_add(g, next_l + ":")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + check_l)
    irg_add(g, found_l + ":")
    irg_add(g, "store i64 " + i + ", ptr " + res_a)
    irg_add(g, "br label %" + end_l)
    irg_add(g, sleep_l + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 0")
    irg_add(g, "store i64 0, ptr " + sp)
    np = irg_new_reg(g)
    irg_add(g, np + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 1")
    irg_add(g, "store i64 1000000, ptr " + np)
    irg_add(g, "call i32 @nanosleep(ptr " + ts + ", ptr null)")
    irg_add(g, "br label %" + scan_l)
    irg_add(g, end_l + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res_a)
    return r
}

# Task.done(): reads the atomic completion flag in the result box.
# Task.wait(ms): polls the completion flag; returns false on timeout; the task is not consumed and can still be awaited.
# Task.cancel(): atomically records a cancellation request; returns false when already done or already requested.
# Task.cancelled(): whether a cancellation request was recorded (does not mean the task ended).
public def irg_codegen_task_method(g: @var IRGen, e: Expr) -> str {
    task = irg_expr_type_name(g, e.object.get(0))
    p = irg_task_payload_of(task)
    is_done = str_eq(e.name, "done")
    is_wait = str_eq(e.name, "wait")
    is_cancel = str_eq(e.name, "cancel")
    is_cancelled = str_eq(e.name, "cancelled")
    if (not is_done and not is_wait and not is_cancel and not is_cancelled) or
       p.len() == 0 {
        return "0"
    }
    irg_ensure_task_box(g, task)
    tv = irg_codegen_expr(g, e.object.get(0))
    h = irg_new_reg(g)
    irg_add(g, h + " = extractvalue %" + task + " " + tv + ", 0")
    box = irg_new_reg(g)
    irg_add(g, box + " = inttoptr i64 " + h + " to ptr")
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr %TaskBox$" + p + ", ptr " + box + ", i32 0, i32 1")
    if is_done {
        d = irg_new_reg(g)
        irg_add(g, d + " = load atomic i64, ptr " + dp + " monotonic, align 8")
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp ne i64 " + d + ", 0")
        return r
    }
    if is_cancelled {
        cp = irg_new_reg(g)
        irg_add(g, cp + " = getelementptr %TaskBox$" + p + ", ptr " + box +
                  ", i32 0, i32 3")
        c = irg_new_reg(g)
        irg_add(g, c + " = load atomic i64, ptr " + cp + " monotonic, align 8")
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp ne i64 " + c + ", 0")
        return r
    }
    if is_cancel {
        cp = irg_new_reg(g)
        irg_add(g, cp + " = getelementptr %TaskBox$" + p + ", ptr " + box +
                  ", i32 0, i32 3")
        out = irg_new_reg(g)
        irg_add(g, out + " = alloca i8")
        done_l = irg_new_label(g, "task.cancel.done")
        req_l = irg_new_label(g, "task.cancel.request")
        end_l = irg_new_label(g, "task.cancel.end")
        d = irg_new_reg(g)
        irg_add(g, d + " = load atomic i64, ptr " + dp + " monotonic, align 8")
        fin = irg_new_reg(g)
        irg_add(g, fin + " = icmp ne i64 " + d + ", 0")
        irg_add(g, "br i1 " + fin + ", label %" + done_l + ", label %" + req_l)
        irg_add(g, done_l + ":")
        irg_add(g, "store i8 0, ptr " + out)
        irg_add(g, "br label %" + end_l)
        irg_add(g, req_l + ":")
        old = irg_new_reg(g)
        irg_add(g, old + " = atomicrmw xchg ptr " + cp + ", i64 1 monotonic, align 8")
        first = irg_new_reg(g)
        irg_add(g, first + " = icmp eq i64 " + old + ", 0")
        z = irg_new_reg(g)
        irg_add(g, z + " = zext i1 " + first + " to i8")
        irg_add(g, "store i8 " + z + ", ptr " + out)
        irg_add(g, "br label %" + end_l)
        irg_add(g, end_l + ":")
        v = irg_new_reg(g)
        irg_add(g, v + " = load i8, ptr " + out)
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp ne i8 " + v + ", 0")
        return r
    }
    # wait(ms): poll done every 1ms; ms <= 0 checks only once.
    ms = irg_codegen_expr(g, e.args.get(0))
    left = irg_new_reg(g)
    irg_add(g, left + " = alloca i64")
    irg_add(g, "store i64 " + ms + ", ptr " + left)
    out = irg_new_reg(g)
    irg_add(g, out + " = alloca i8")
    ts = irg_new_reg(g)
    irg_add(g, ts + " = alloca [2 x i64]")
    loop_l = irg_new_label(g, "task.wait.loop")
    check_l = irg_new_label(g, "task.wait.check")
    sleep_l = irg_new_label(g, "task.wait.sleep")
    ok_l = irg_new_label(g, "task.wait.ok")
    timeout_l = irg_new_label(g, "task.wait.timeout")
    end_l = irg_new_label(g, "task.wait.end")
    irg_add(g, "br label %" + loop_l)
    irg_add(g, loop_l + ":")
    d = irg_new_reg(g)
    irg_add(g, d + " = load atomic i64, ptr " + dp + " monotonic, align 8")
    fin = irg_new_reg(g)
    irg_add(g, fin + " = icmp ne i64 " + d + ", 0")
    irg_add(g, "br i1 " + fin + ", label %" + ok_l + ", label %" + check_l)
    irg_add(g, check_l + ":")
    n = irg_new_reg(g)
    irg_add(g, n + " = load i64, ptr " + left)
    exp = irg_new_reg(g)
    irg_add(g, exp + " = icmp sle i64 " + n + ", 0")
    irg_add(g, "br i1 " + exp + ", label %" + timeout_l + ", label %" + sleep_l)
    irg_add(g, sleep_l + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 0")
    irg_add(g, "store i64 0, ptr " + sp)
    np = irg_new_reg(g)
    irg_add(g, np + " = getelementptr [2 x i64], ptr " + ts + ", i32 0, i32 1")
    irg_add(g, "store i64 1000000, ptr " + np)
    irg_add(g, "call i32 @nanosleep(ptr " + ts + ", ptr null)")
    m = irg_new_reg(g)
    irg_add(g, m + " = load i64, ptr " + left)
    m2 = irg_new_reg(g)
    irg_add(g, m2 + " = sub i64 " + m + ", 1")
    irg_add(g, "store i64 " + m2 + ", ptr " + left)
    irg_add(g, "br label %" + loop_l)
    irg_add(g, ok_l + ":")
    irg_add(g, "store i8 1, ptr " + out)
    irg_add(g, "br label %" + end_l)
    irg_add(g, timeout_l + ":")
    irg_add(g, "store i8 0, ptr " + out)
    irg_add(g, "br label %" + end_l)
    irg_add(g, end_l + ":")
    v = irg_new_reg(g)
    irg_add(g, v + " = load i8, ptr " + out)
    r = irg_new_reg(g)
    irg_add(g, r + " = icmp ne i8 " + v + ", 0")
    return r
}

# ---------------------------------------------------------------------------
# str methods
# ---------------------------------------------------------------------------

public def irg_codegen_str_method(g: @var IRGen, e: Expr) -> str {
    s = irg_codegen_expr(g, e.object.get(0))
    if e.name == "len" {
        r = irg_new_reg(g)
        irg_add(g, r + " = call i64 @strlen(ptr " + s + ")")
        return r
    } elif e.name == "contains" {
        sub = irg_codegen_expr(g, e.args.get(0))
        f = irg_new_reg(g)
        irg_add(g, f + " = call ptr @strstr(ptr " + s + ", ptr " + sub + ")")
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp ne ptr " + f + ", null")
        return r
    } elif e.name == "startswith" {
        sub = irg_codegen_expr(g, e.args.get(0))
        sl = irg_new_reg(g)
        irg_add(g, sl + " = call i64 @strlen(ptr " + s + ")")
        subl = irg_new_reg(g)
        irg_add(g, subl + " = call i64 @strlen(ptr " + sub + ")")
        cmp = irg_new_reg(g)
        irg_add(g, cmp + " = call i32 @strncmp(ptr " + sub + ", ptr " + s + ", i64 " + subl + ")")
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp eq i32 " + cmp + ", 0")
        return r
    } elif e.name == "endswith" {
        sub = irg_codegen_expr(g, e.args.get(0))
        sl = irg_new_reg(g)
        irg_add(g, sl + " = call i64 @strlen(ptr " + s + ")")
        subl = irg_new_reg(g)
        irg_add(g, subl + " = call i64 @strlen(ptr " + sub + ")")
        too_long = irg_new_reg(g)
        irg_add(g, too_long + " = icmp ugt i64 " + subl + ", " + sl)
        too_label = irg_new_label(g, "es.too")
        check_label = irg_new_label(g, "es.check")
        end_label = irg_new_label(g, "es.end")
        irg_add(g, "br i1 " + too_long + ", label %" + too_label + ", label %" + check_label)
        irg_add(g, too_label + ":")
        irg_add(g, "br label %" + end_label)
        irg_add(g, check_label + ":")
        off = irg_new_reg(g)
        irg_add(g, off + " = sub i64 " + sl + ", " + subl)
        tail = irg_new_reg(g)
        irg_add(g, tail + " = getelementptr i8, ptr " + s + ", i64 " + off)
        cmp = irg_new_reg(g)
        irg_add(g, cmp + " = call i32 @strncmp(ptr " + tail + ", ptr " + sub + ", i64 " + subl + ")")
        cv = irg_new_reg(g)
        irg_add(g, cv + " = icmp eq i32 " + cmp + ", 0")
        irg_add(g, "br label %" + end_label)
        irg_add(g, end_label + ":")
        r = irg_new_reg(g)
        irg_add(g, r + " = phi i1 [ false, %" + too_label + " ], [ " + cv + ", %" + check_label + " ]")
        return r
    } elif e.name == "char_at" {
        idx = irg_codegen_expr(g, e.args.get(0))
        p = irg_new_reg(g)
        irg_add(g, p + " = getelementptr i8, ptr " + s + ", i64 " + idx)
        b = irg_new_reg(g)
        irg_add(g, b + " = load i8, ptr " + p)
        r = irg_new_reg(g)
        irg_add(g, r + " = zext i8 " + b + " to i64")
        return r
    } elif e.name == "slice" {
        start = irg_codegen_expr(g, e.args.get(0))
        end = irg_codegen_expr(g, e.args.get(1))
        len = irg_new_reg(g)
        irg_add(g, len + " = sub i64 " + end + ", " + start)
        neg = irg_new_reg(g)
        irg_add(g, neg + " = icmp slt i64 " + len + ", 0")
        len2 = irg_new_reg(g)
        irg_add(g, len2 + " = select i1 " + neg + ", i64 0, i64 " + len)
        alloc = irg_new_reg(g)
        irg_add(g, alloc + " = add i64 " + len2 + ", 1")
        buf = irg_new_reg(g)
        irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")
        src = irg_new_reg(g)
        irg_add(g, src + " = getelementptr i8, ptr " + s + ", i64 " + start)
        mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + buf + ", ptr " + src + ", i64 " + len2 + ")")
        nul = irg_new_reg(g)
        irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + len2)
        irg_add(g, "store i8 0, ptr " + nul)
        return buf
    } elif e.name == "to_int" {
        result_name = "Result$int$str"
        endptr_a = irg_new_reg(g)
        irg_add(g, endptr_a + " = alloca ptr")
        irg_add(g, "store ptr null, ptr " + endptr_a)
        val = irg_new_reg(g)
        irg_add(g, val + " = call i64 @strtoll(ptr " + s + ", ptr " + endptr_a + ", i32 10)")
        endptr = irg_new_reg(g)
        irg_add(g, endptr + " = load ptr, ptr " + endptr_a)
        parsed = irg_new_reg(g)
        irg_add(g, parsed + " = icmp ne ptr " + endptr + ", " + s)
        ok_label = irg_new_label(g, "ti.ok")
        err_label = irg_new_label(g, "ti.err")
        merge_label = irg_new_label(g, "ti.end")
        irg_add(g, "br i1 " + parsed + ", label %" + ok_label + ", label %" + err_label)
        res_a = irg_new_reg(g)
        irg_add(g, res_a + " = alloca %" + result_name)
        irg_add(g, ok_label + ":")
        irg_ensure_enum_layout(g, result_name)
        irg_ensure_type(g, result_name)
        oa = irg_new_reg(g)
        irg_add(g, oa + " = alloca %" + result_name)
        od = irg_new_reg(g)
        irg_add(g, od + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 0")
        irg_add(g, "store i8 0, ptr " + od)
        op = irg_new_reg(g)
        irg_add(g, op + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 1, i32 0")
        irg_add(g, "store i64 " + val + ", ptr " + op)
        ov = irg_new_reg(g)
        irg_add(g, ov + " = load %" + result_name + ", ptr " + oa)
        irg_add(g, "store %" + result_name + " " + ov + ", ptr " + res_a)
        irg_add(g, "br label %" + merge_label)
        irg_add(g, err_label + ":")
        ea = irg_new_reg(g)
        irg_add(g, ea + " = alloca %" + result_name)
        ed = irg_new_reg(g)
        irg_add(g, ed + " = getelementptr %" + result_name + ", ptr " + ea + ", i32 0, i32 0")
        irg_add(g, "store i8 1, ptr " + ed)
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr %" + result_name + ", ptr " + ea + ", i32 0, i32 1, i32 0")
        emsg = irg_emit_string_const(g, "invalid integer literal")
        emsg_bits = irg_payload_bits(g, "str", emsg)
        irg_add(g, "store i64 " + emsg_bits + ", ptr " + ep)
        ev = irg_new_reg(g)
        irg_add(g, ev + " = load %" + result_name + ", ptr " + ea)
        irg_add(g, "store %" + result_name + " " + ev + ", ptr " + res_a)
        irg_add(g, "br label %" + merge_label)
        irg_add(g, merge_label + ":")
        r = irg_new_reg(g)
        irg_add(g, r + " = load %" + result_name + ", ptr " + res_a)
        return r
    } elif e.name == "to_float" {
        result_name = "Result$float$str"
        endptr_a = irg_new_reg(g)
        irg_add(g, endptr_a + " = alloca ptr")
        irg_add(g, "store ptr null, ptr " + endptr_a)
        val = irg_new_reg(g)
        irg_add(g, val + " = call double @strtod(ptr " + s + ", ptr " + endptr_a + ")")
        endptr = irg_new_reg(g)
        irg_add(g, endptr + " = load ptr, ptr " + endptr_a)
        consumed = irg_new_reg(g)
        irg_add(g, consumed + " = icmp ne ptr " + endptr + ", " + s)
        tail = irg_new_reg(g)
        irg_add(g, tail + " = load i8, ptr " + endptr)
        at_end = irg_new_reg(g)
        irg_add(g, at_end + " = icmp eq i8 " + tail + ", 0")
        parsed = irg_new_reg(g)
        irg_add(g, parsed + " = and i1 " + consumed + ", " + at_end)
        ok_label = irg_new_label(g, "tf.ok")
        err_label = irg_new_label(g, "tf.err")
        merge_label = irg_new_label(g, "tf.end")
        irg_add(g, "br i1 " + parsed + ", label %" + ok_label + ", label %" + err_label)
        res_a = irg_new_reg(g)
        irg_add(g, res_a + " = alloca %" + result_name)
        irg_add(g, ok_label + ":")
        irg_ensure_enum_layout(g, result_name)
        irg_ensure_type(g, result_name)
        oa = irg_new_reg(g)
        irg_add(g, oa + " = alloca %" + result_name)
        od = irg_new_reg(g)
        irg_add(g, od + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 0")
        irg_add(g, "store i8 0, ptr " + od)
        op = irg_new_reg(g)
        irg_add(g, op + " = getelementptr %" + result_name + ", ptr " + oa + ", i32 0, i32 1, i32 0")
        bits = irg_payload_bits(g, "float", val)
        irg_add(g, "store i64 " + bits + ", ptr " + op)
        ov = irg_new_reg(g)
        irg_add(g, ov + " = load %" + result_name + ", ptr " + oa)
        irg_add(g, "store %" + result_name + " " + ov + ", ptr " + res_a)
        irg_add(g, "br label %" + merge_label)
        irg_add(g, err_label + ":")
        ea = irg_new_reg(g)
        irg_add(g, ea + " = alloca %" + result_name)
        ed = irg_new_reg(g)
        irg_add(g, ed + " = getelementptr %" + result_name + ", ptr " + ea + ", i32 0, i32 0")
        irg_add(g, "store i8 1, ptr " + ed)
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr %" + result_name + ", ptr " + ea + ", i32 0, i32 1, i32 0")
        emsg = irg_emit_string_const(g, "invalid float literal")
        emsg_bits = irg_payload_bits(g, "str", emsg)
        irg_add(g, "store i64 " + emsg_bits + ", ptr " + ep)
        ev = irg_new_reg(g)
        irg_add(g, ev + " = load %" + result_name + ", ptr " + ea)
        irg_add(g, "store %" + result_name + " " + ev + ", ptr " + res_a)
        irg_add(g, "br label %" + merge_label)
        irg_add(g, merge_label + ":")
        r = irg_new_reg(g)
        irg_add(g, r + " = load %" + result_name + ", ptr " + res_a)
        return r
    } elif e.name == "split" {
        return irg_codegen_str_split(g, e)
    } elif e.name == "join" {
        return irg_codegen_str_join(g, e)
    } elif e.name == "trim" {
        return irg_str_trim(g, s, 1, 1)
    } elif e.name == "trim_start" {
        return irg_str_trim(g, s, 1, 0)
    } elif e.name == "trim_end" {
        return irg_str_trim(g, s, 0, 1)
    } elif e.name == "find" {
        sub = irg_codegen_expr(g, e.args.get(0))
        return irg_str_find_first(g, s, sub)
    } elif e.name == "rfind" {
        sub = irg_codegen_expr(g, e.args.get(0))
        return irg_str_find_last(g, s, sub)
    } elif e.name == "replace" {
        old = irg_codegen_expr(g, e.args.get(0))
        repl = irg_codegen_expr(g, e.args.get(1))
        return irg_str_replace(g, s, old, repl)
    } elif e.name == "repeat" {
        n = irg_codegen_expr(g, e.args.get(0))
        return irg_str_repeat(g, s, n)
    } elif e.name == "lines" {
        return irg_str_lines(g, s)
    }
    return "0"
}
public def irg_codegen_str_split(g: @var IRGen, e: Expr) -> str {
    s = irg_codegen_expr(g, e.object.get(0))
    sep = irg_codegen_expr(g, e.args.get(0))
    list_name = "List$str"
    irg_ensure_type(g, list_name)

    fn = g.cur_fn
    list_a = irg_new_reg(g)
    irg_add(g, list_a + " = alloca %List$str")
    irg_add(g, "store %List$str zeroinitializer, ptr " + list_a)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %List$str, ptr " + list_a + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr %List$str, ptr " + list_a + ", i32 0, i32 1")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr %List$str, ptr " + list_a + ", i32 0, i32 2")

    sep_len = irg_new_reg(g)
    irg_add(g, sep_len + " = call i64 @strlen(ptr " + sep + ")")
    s_len = irg_new_reg(g)
    irg_add(g, s_len + " = call i64 @strlen(ptr " + s + ")")

    data0 = irg_new_reg(g)
    irg_add(g, data0 + " = call ptr @malloc(i64 32)")
    irg_add(g, "store ptr " + data0 + ", ptr " + data_p)
    irg_add(g, "store i64 4, ptr " + cap_p)

    pos_a = irg_new_reg(g)
    irg_add(g, pos_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + pos_a)

    cond_label = irg_new_label(g, "sp.cond")
    find_label = irg_new_label(g, "sp.find")
    tail_label = irg_new_label(g, "sp.tail")
    inc_label = irg_new_label(g, "sp.inc")
    exit_label = irg_new_label(g, "sp.exit")
    irg_add(g, "br label %" + cond_label)
    irg_add(g, cond_label + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + pos + ", " + s_len)
    irg_add(g, "br i1 " + more + ", label %" + find_label + ", label %" + exit_label)

    irg_add(g, find_label + ":")
    cur = irg_new_reg(g)
    irg_add(g, cur + " = getelementptr i8, ptr " + s + ", i64 " + pos)
    found = irg_new_reg(g)
    irg_add(g, found + " = call ptr @strstr(ptr " + cur + ", ptr " + sep + ")")
    found_null = irg_new_reg(g)
    irg_add(g, found_null + " = icmp eq ptr " + found + ", null")
    irg_add(g, "br i1 " + found_null + ", label %" + tail_label + ", label %" + inc_label)

    irg_add(g, tail_label + ":")
    tail_len = irg_new_reg(g)
    irg_add(g, tail_len + " = sub i64 " + s_len + ", " + pos)
    tail_alloc = irg_new_reg(g)
    irg_add(g, tail_alloc + " = add i64 " + tail_len + ", 1")
    tail_buf = irg_new_reg(g)
    irg_add(g, tail_buf + " = call ptr @malloc(i64 " + tail_alloc + ")")
    mt = irg_new_reg(g)
    irg_add(g, mt + " = call ptr @memcpy(ptr " + tail_buf + ", ptr " + cur + ", i64 " + tail_len + ")")
    tail_nul = irg_new_reg(g)
    irg_add(g, tail_nul + " = getelementptr i8, ptr " + tail_buf + ", i64 " + tail_len)
    irg_add(g, "store i8 0, ptr " + tail_nul)
    irg_list_push(g, list_a, "List$str", "str", tail_buf)
    irg_add(g, "br label %" + exit_label)

    irg_add(g, inc_label + ":")
    found_pos = irg_new_reg(g)
    irg_add(g, found_pos + " = ptrtoint ptr " + found + " to i64")
    s_int = irg_new_reg(g)
    irg_add(g, s_int + " = ptrtoint ptr " + s + " to i64")
    fpos = irg_new_reg(g)
    irg_add(g, fpos + " = sub i64 " + found_pos + ", " + s_int)
    seg_len = irg_new_reg(g)
    irg_add(g, seg_len + " = sub i64 " + fpos + ", " + pos)
    seg_alloc = irg_new_reg(g)
    irg_add(g, seg_alloc + " = add i64 " + seg_len + ", 1")
    seg_buf = irg_new_reg(g)
    irg_add(g, seg_buf + " = call ptr @malloc(i64 " + seg_alloc + ")")
    ms = irg_new_reg(g)
    irg_add(g, ms + " = call ptr @memcpy(ptr " + seg_buf + ", ptr " + cur + ", i64 " + seg_len + ")")
    seg_nul = irg_new_reg(g)
    irg_add(g, seg_nul + " = getelementptr i8, ptr " + seg_buf + ", i64 " + seg_len)
    irg_add(g, "store i8 0, ptr " + seg_nul)
    irg_list_push(g, list_a, "List$str", "str", seg_buf)
    next_pos = irg_new_reg(g)
    irg_add(g, next_pos + " = add i64 " + fpos + ", " + sep_len)
    irg_add(g, "store i64 " + next_pos + ", ptr " + pos_a)
    irg_add(g, "br label %" + cond_label)

    irg_add(g, exit_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %List$str, ptr " + list_a)
    return r
}

# str.join(parts: List[str]) -> str
public def irg_codegen_str_join(g: @var IRGen, e: Expr) -> str {
    sep = irg_codegen_expr(g, e.object.get(0))
    parts = irg_codegen_expr(g, e.args.get(0))
    list_name = "List$str"
    irg_ensure_type(g, list_name)
    parts_a = irg_new_reg(g)
    irg_add(g, parts_a + " = alloca %List$str")
    irg_add(g, "store %List$str " + parts + ", ptr " + parts_a)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %List$str, ptr " + parts_a + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr %List$str, ptr " + parts_a + ", i32 0, i32 1")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    sep_len = irg_new_reg(g)
    irg_add(g, sep_len + " = call i64 @strlen(ptr " + sep + ")")

    # Loop 1: total = sum(strlen(part)).
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    total_a = irg_new_reg(g)
    irg_add(g, total_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + total_a)
    c1 = irg_new_label(g, "jp.c1")
    b1 = irg_new_label(g, "jp.b1")
    a1 = irg_new_label(g, "jp.a1")
    irg_add(g, "br label %" + c1)
    irg_add(g, c1 + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    m1 = irg_new_reg(g)
    irg_add(g, m1 + " = icmp slt i64 " + i + ", " + len)
    irg_add(g, "br i1 " + m1 + ", label %" + b1 + ", label %" + a1)
    irg_add(g, b1 + ":")
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr ptr, ptr " + data + ", i64 " + i)
    elem = irg_new_reg(g)
    irg_add(g, elem + " = load ptr, ptr " + ep)
    el = irg_new_reg(g)
    irg_add(g, el + " = call i64 @strlen(ptr " + elem + ")")
    tot = irg_new_reg(g)
    irg_add(g, tot + " = load i64, ptr " + total_a)
    tot2 = irg_new_reg(g)
    irg_add(g, tot2 + " = add i64 " + tot + ", " + el)
    irg_add(g, "store i64 " + tot2 + ", ptr " + total_a)
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c1)

    irg_add(g, a1 + ":")
    total_f = irg_new_reg(g)
    irg_add(g, total_f + " = load i64, ptr " + total_a)
    sep_count = irg_new_reg(g)
    irg_add(g, sep_count + " = sub i64 " + len + ", 1")
    sep_bytes = irg_new_reg(g)
    irg_add(g, sep_bytes + " = mul i64 " + sep_count + ", " + sep_len)
    has_sep = irg_new_reg(g)
    irg_add(g, has_sep + " = icmp sgt i64 " + len + ", 1")
    sep_add = irg_new_reg(g)
    irg_add(g, sep_add + " = select i1 " + has_sep + ", i64 " + sep_bytes + ", i64 0")
    grand = irg_new_reg(g)
    irg_add(g, grand + " = add i64 " + total_f + ", " + sep_add)
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + grand + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")

    # Loop 2: copy part by part.
    out_a = irg_new_reg(g)
    irg_add(g, out_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + out_a)
    i2_a = irg_new_reg(g)
    irg_add(g, i2_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i2_a)
    c2 = irg_new_label(g, "jp.c2")
    b2 = irg_new_label(g, "jp.b2")
    s2 = irg_new_label(g, "jp.sep")
    k2 = irg_new_label(g, "jp.skip")
    a2 = irg_new_label(g, "jp.a2")
    irg_add(g, "br label %" + c2)
    irg_add(g, c2 + ":")
    i3 = irg_new_reg(g)
    irg_add(g, i3 + " = load i64, ptr " + i2_a)
    m2 = irg_new_reg(g)
    irg_add(g, m2 + " = icmp slt i64 " + i3 + ", " + len)
    irg_add(g, "br i1 " + m2 + ", label %" + b2 + ", label %" + a2)
    irg_add(g, b2 + ":")
    out = irg_new_reg(g)
    irg_add(g, out + " = load i64, ptr " + out_a)
    ep2 = irg_new_reg(g)
    irg_add(g, ep2 + " = getelementptr ptr, ptr " + data + ", i64 " + i3)
    elem2 = irg_new_reg(g)
    irg_add(g, elem2 + " = load ptr, ptr " + ep2)
    el2 = irg_new_reg(g)
    irg_add(g, el2 + " = call i64 @strlen(ptr " + elem2 + ")")
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + out)
    me = irg_new_reg(g)
    irg_add(g, me + " = call ptr @memcpy(ptr " + dst + ", ptr " + elem2 + ", i64 " + el2 + ")")
    out2 = irg_new_reg(g)
    irg_add(g, out2 + " = add i64 " + out + ", " + el2)
    irg_add(g, "store i64 " + out2 + ", ptr " + out_a)
    i_next = irg_new_reg(g)
    irg_add(g, i_next + " = add i64 " + i3 + ", 1")
    not_last = irg_new_reg(g)
    irg_add(g, not_last + " = icmp slt i64 " + i_next + ", " + len)
    irg_add(g, "br i1 " + not_last + ", label %" + s2 + ", label %" + k2)
    irg_add(g, s2 + ":")
    out3 = irg_new_reg(g)
    irg_add(g, out3 + " = load i64, ptr " + out_a)
    dst2 = irg_new_reg(g)
    irg_add(g, dst2 + " = getelementptr i8, ptr " + buf + ", i64 " + out3)
    msep = irg_new_reg(g)
    irg_add(g, msep + " = call ptr @memcpy(ptr " + dst2 + ", ptr " + sep + ", i64 " + sep_len + ")")
    out4 = irg_new_reg(g)
    irg_add(g, out4 + " = add i64 " + out3 + ", " + sep_len)
    irg_add(g, "store i64 " + out4 + ", ptr " + out_a)
    irg_add(g, "br label %" + k2)
    irg_add(g, k2 + ":")
    i4 = irg_new_reg(g)
    irg_add(g, i4 + " = add i64 " + i3 + ", 1")
    irg_add(g, "store i64 " + i4 + ", ptr " + i2_a)
    irg_add(g, "br label %" + c2)
    irg_add(g, a2 + ":")
    out_f = irg_new_reg(g)
    irg_add(g, out_f + " = load i64, ptr " + out_a)
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + out_f)
    irg_add(g, "store i8 0, ptr " + nul)
    return buf
}

# ---------------------------------------------------------------------------
# str helpers: trim / find / replace / repeat / lines
# ---------------------------------------------------------------------------

public def irg_is_space(g: @var IRGen, c: str) -> str {
    is32 = irg_new_reg(g)
    irg_add(g, is32 + " = icmp eq i64 " + c + ", 32")
    ge9 = irg_new_reg(g)
    irg_add(g, ge9 + " = icmp sge i64 " + c + ", 9")
    le13 = irg_new_reg(g)
    irg_add(g, le13 + " = icmp sle i64 " + c + ", 13")
    rng = irg_new_reg(g)
    irg_add(g, rng + " = and i1 " + ge9 + ", " + le13)
    r = irg_new_reg(g)
    irg_add(g, r + " = or i1 " + is32 + ", " + rng)
    return r
}

# Copy s[start..end) into a fresh NUL-terminated buffer.
public def irg_str_copy_range(g: @var IRGen, s: str, start: str, end: str) -> str {
    n = irg_new_reg(g)
    irg_add(g, n + " = sub i64 " + end + ", " + start)
    neg = irg_new_reg(g)
    irg_add(g, neg + " = icmp slt i64 " + n + ", 0")
    n2 = irg_new_reg(g)
    irg_add(g, n2 + " = select i1 " + neg + ", i64 0, i64 " + n)
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + n2 + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")
    src = irg_new_reg(g)
    irg_add(g, src + " = getelementptr i8, ptr " + s + ", i64 " + start)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + buf + ", ptr " + src + ", i64 " + n2 + ")")
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + n2)
    irg_add(g, "store i8 0, ptr " + nul)
    return buf
}

# Trim ASCII whitespace from the left and/or right.
public def irg_str_trim(g: @var IRGen, s: str, do_left: int, do_right: int) -> str {
    ln = irg_new_reg(g)
    irg_add(g, ln + " = call i64 @strlen(ptr " + s + ")")
    start_a = irg_new_reg(g)
    irg_add(g, start_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + start_a)
    end_a = irg_new_reg(g)
    irg_add(g, end_a + " = alloca i64")
    irg_add(g, "store i64 " + ln + ", ptr " + end_a)
    if do_left == 1 {
        c1 = irg_new_label(g, "tr.lc")
        b1 = irg_new_label(g, "tr.lb")
        a1 = irg_new_label(g, "tr.la")
        e1 = irg_new_label(g, "tr.le")
        irg_add(g, "br label %" + c1)
        irg_add(g, c1 + ":")
        st = irg_new_reg(g)
        irg_add(g, st + " = load i64, ptr " + start_a)
        more = irg_new_reg(g)
        irg_add(g, more + " = icmp slt i64 " + st + ", " + ln)
        irg_add(g, "br i1 " + more + ", label %" + b1 + ", label %" + e1)
        irg_add(g, b1 + ":")
        p = irg_new_reg(g)
        irg_add(g, p + " = getelementptr i8, ptr " + s + ", i64 " + st)
        ch = irg_new_reg(g)
        irg_add(g, ch + " = load i8, ptr " + p)
        z = irg_new_reg(g)
        irg_add(g, z + " = zext i8 " + ch + " to i64")
        sp = irg_is_space(g, z)
        irg_add(g, "br i1 " + sp + ", label %" + a1 + ", label %" + e1)
        irg_add(g, a1 + ":")
        st2 = irg_new_reg(g)
        irg_add(g, st2 + " = add i64 " + st + ", 1")
        irg_add(g, "store i64 " + st2 + ", ptr " + start_a)
        irg_add(g, "br label %" + c1)
        irg_add(g, e1 + ":")
    }
    if do_right == 1 {
        c2 = irg_new_label(g, "tr.rc")
        b2 = irg_new_label(g, "tr.rb")
        a2 = irg_new_label(g, "tr.ra")
        e2 = irg_new_label(g, "tr.re")
        irg_add(g, "br label %" + c2)
        irg_add(g, c2 + ":")
        en = irg_new_reg(g)
        irg_add(g, en + " = load i64, ptr " + end_a)
        more = irg_new_reg(g)
        irg_add(g, more + " = icmp sgt i64 " + en + ", 0")
        irg_add(g, "br i1 " + more + ", label %" + b2 + ", label %" + e2)
        irg_add(g, b2 + ":")
        prev = irg_new_reg(g)
        irg_add(g, prev + " = sub i64 " + en + ", 1")
        p = irg_new_reg(g)
        irg_add(g, p + " = getelementptr i8, ptr " + s + ", i64 " + prev)
        ch = irg_new_reg(g)
        irg_add(g, ch + " = load i8, ptr " + p)
        z = irg_new_reg(g)
        irg_add(g, z + " = zext i8 " + ch + " to i64")
        sp = irg_is_space(g, z)
        irg_add(g, "br i1 " + sp + ", label %" + a2 + ", label %" + e2)
        irg_add(g, a2 + ":")
        en2 = irg_new_reg(g)
        irg_add(g, en2 + " = sub i64 " + en + ", 1")
        irg_add(g, "store i64 " + en2 + ", ptr " + end_a)
        irg_add(g, "br label %" + c2)
        irg_add(g, e2 + ":")
    }
    st = irg_new_reg(g)
    irg_add(g, st + " = load i64, ptr " + start_a)
    en = irg_new_reg(g)
    irg_add(g, en + " = load i64, ptr " + end_a)
    lt = irg_new_reg(g)
    irg_add(g, lt + " = icmp slt i64 " + en + ", " + st)
    en2 = irg_new_reg(g)
    irg_add(g, en2 + " = select i1 " + lt + ", i64 " + st + ", i64 " + en)
    return irg_str_copy_range(g, s, st, en2)
}

public def irg_str_find_first(g: @var IRGen, s: str, sub: str) -> str {
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca i64")
    irg_add(g, "store i64 -1, ptr " + res_a)
    sub_len = irg_new_reg(g)
    irg_add(g, sub_len + " = call i64 @strlen(ptr " + sub + ")")
    empty = irg_new_reg(g)
    irg_add(g, empty + " = icmp eq i64 " + sub_len + ", 0")
    empty_label = irg_new_label(g, "ff.empty")
    search_label = irg_new_label(g, "ff.search")
    hit_label = irg_new_label(g, "ff.hit")
    end_label = irg_new_label(g, "ff.end")
    irg_add(g, "br i1 " + empty + ", label %" + empty_label + ", label %" + search_label)
    irg_add(g, empty_label + ":")
    irg_add(g, "store i64 0, ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, search_label + ":")
    f = irg_new_reg(g)
    irg_add(g, f + " = call ptr @strstr(ptr " + s + ", ptr " + sub + ")")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + f + ", null")
    irg_add(g, "br i1 " + isnull + ", label %" + end_label + ", label %" + hit_label)
    irg_add(g, hit_label + ":")
    si = irg_new_reg(g)
    irg_add(g, si + " = ptrtoint ptr " + s + " to i64")
    fi = irg_new_reg(g)
    irg_add(g, fi + " = ptrtoint ptr " + f + " to i64")
    off = irg_new_reg(g)
    irg_add(g, off + " = sub i64 " + fi + ", " + si)
    irg_add(g, "store i64 " + off + ", ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res_a)
    return r
}

public def irg_str_find_last(g: @var IRGen, s: str, sub: str) -> str {
    s_len = irg_new_reg(g)
    irg_add(g, s_len + " = call i64 @strlen(ptr " + s + ")")
    sub_len = irg_new_reg(g)
    irg_add(g, sub_len + " = call i64 @strlen(ptr " + sub + ")")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca i64")
    irg_add(g, "store i64 -1, ptr " + res_a)
    pos_a = irg_new_reg(g)
    irg_add(g, pos_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + pos_a)
    c_label = irg_new_label(g, "fl.cond")
    b_label = irg_new_label(g, "fl.body")
    h_label = irg_new_label(g, "fl.hit")
    n_label = irg_new_label(g, "fl.next")
    e_label = irg_new_label(g, "fl.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    bound = irg_new_reg(g)
    irg_add(g, bound + " = add i64 " + pos + ", " + sub_len)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp sle i64 " + bound + ", " + s_len)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    cur = irg_new_reg(g)
    irg_add(g, cur + " = getelementptr i8, ptr " + s + ", i64 " + pos)
    cmp = irg_new_reg(g)
    irg_add(g, cmp + " = call i32 @strncmp(ptr " + cur + ", ptr " + sub + ", i64 " + sub_len + ")")
    eq = irg_new_reg(g)
    irg_add(g, eq + " = icmp eq i32 " + cmp + ", 0")
    irg_add(g, "br i1 " + eq + ", label %" + h_label + ", label %" + n_label)
    irg_add(g, h_label + ":")
    irg_add(g, "store i64 " + pos + ", ptr " + res_a)
    irg_add(g, "br label %" + n_label)
    irg_add(g, n_label + ":")
    pos2 = irg_new_reg(g)
    irg_add(g, pos2 + " = add i64 " + pos + ", 1")
    irg_add(g, "store i64 " + pos2 + ", ptr " + pos_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + res_a)
    return r
}

# Replace every non-overlapping occurrence of old with repl.
public def irg_str_replace(g: @var IRGen, s: str, old: str, repl: str) -> str {
    s_len = irg_new_reg(g)
    irg_add(g, s_len + " = call i64 @strlen(ptr " + s + ")")
    old_len = irg_new_reg(g)
    irg_add(g, old_len + " = call i64 @strlen(ptr " + old + ")")
    new_len = irg_new_reg(g)
    irg_add(g, new_len + " = call i64 @strlen(ptr " + repl + ")")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca ptr")
    irg_add(g, "store ptr " + s + ", ptr " + res_a)
    zero_old = irg_new_reg(g)
    irg_add(g, zero_old + " = icmp eq i64 " + old_len + ", 0")
    count_label = irg_new_label(g, "rp.count")
    end_label = irg_new_label(g, "rp.end")
    irg_add(g, "br i1 " + zero_old + ", label %" + end_label + ", label %" + count_label)
    irg_add(g, count_label + ":")
    pos_a = irg_new_reg(g)
    irg_add(g, pos_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + pos_a)
    cnt_a = irg_new_reg(g)
    irg_add(g, cnt_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + cnt_a)
    c1 = irg_new_label(g, "rp.c1")
    h1 = irg_new_label(g, "rp.h1")
    e1 = irg_new_label(g, "rp.e1")
    irg_add(g, "br label %" + c1)
    irg_add(g, c1 + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    cur = irg_new_reg(g)
    irg_add(g, cur + " = getelementptr i8, ptr " + s + ", i64 " + pos)
    f = irg_new_reg(g)
    irg_add(g, f + " = call ptr @strstr(ptr " + cur + ", ptr " + old + ")")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + f + ", null")
    irg_add(g, "br i1 " + isnull + ", label %" + e1 + ", label %" + h1)
    irg_add(g, h1 + ":")
    fi = irg_new_reg(g)
    irg_add(g, fi + " = ptrtoint ptr " + f + " to i64")
    si = irg_new_reg(g)
    irg_add(g, si + " = ptrtoint ptr " + s + " to i64")
    fpos = irg_new_reg(g)
    irg_add(g, fpos + " = sub i64 " + fi + ", " + si)
    next = irg_new_reg(g)
    irg_add(g, next + " = add i64 " + fpos + ", " + old_len)
    irg_add(g, "store i64 " + next + ", ptr " + pos_a)
    cnt = irg_new_reg(g)
    irg_add(g, cnt + " = load i64, ptr " + cnt_a)
    cnt2 = irg_new_reg(g)
    irg_add(g, cnt2 + " = add i64 " + cnt + ", 1")
    irg_add(g, "store i64 " + cnt2 + ", ptr " + cnt_a)
    irg_add(g, "br label %" + c1)
    irg_add(g, e1 + ":")
    cnt = irg_new_reg(g)
    irg_add(g, cnt + " = load i64, ptr " + cnt_a)
    diff = irg_new_reg(g)
    irg_add(g, diff + " = sub i64 " + new_len + ", " + old_len)
    extra = irg_new_reg(g)
    irg_add(g, extra + " = mul i64 " + cnt + ", " + diff)
    out_len = irg_new_reg(g)
    irg_add(g, out_len + " = add i64 " + s_len + ", " + extra)
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + out_len + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")
    irg_add(g, "store i64 0, ptr " + pos_a)
    out_a = irg_new_reg(g)
    irg_add(g, out_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + out_a)
    c2 = irg_new_label(g, "rp.c2")
    h2 = irg_new_label(g, "rp.h2")
    n2_label = irg_new_label(g, "rp.n2")
    t2 = irg_new_label(g, "rp.tail")
    irg_add(g, "br label %" + c2)
    irg_add(g, c2 + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    cur = irg_new_reg(g)
    irg_add(g, cur + " = getelementptr i8, ptr " + s + ", i64 " + pos)
    f = irg_new_reg(g)
    irg_add(g, f + " = call ptr @strstr(ptr " + cur + ", ptr " + old + ")")
    isnull = irg_new_reg(g)
    irg_add(g, isnull + " = icmp eq ptr " + f + ", null")
    irg_add(g, "br i1 " + isnull + ", label %" + t2 + ", label %" + h2)
    irg_add(g, h2 + ":")
    fi = irg_new_reg(g)
    irg_add(g, fi + " = ptrtoint ptr " + f + " to i64")
    si = irg_new_reg(g)
    irg_add(g, si + " = ptrtoint ptr " + s + " to i64")
    fpos = irg_new_reg(g)
    irg_add(g, fpos + " = sub i64 " + fi + ", " + si)
    seg = irg_new_reg(g)
    irg_add(g, seg + " = sub i64 " + fpos + ", " + pos)
    out = irg_new_reg(g)
    irg_add(g, out + " = load i64, ptr " + out_a)
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + out)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + cur + ", i64 " + seg + ")")
    out2 = irg_new_reg(g)
    irg_add(g, out2 + " = add i64 " + out + ", " + seg)
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + out2)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + repl + ", i64 " + new_len + ")")
    out3 = irg_new_reg(g)
    irg_add(g, out3 + " = add i64 " + out2 + ", " + new_len)
    irg_add(g, "store i64 " + out3 + ", ptr " + out_a)
    next = irg_new_reg(g)
    irg_add(g, next + " = add i64 " + fpos + ", " + old_len)
    irg_add(g, "store i64 " + next + ", ptr " + pos_a)
    irg_add(g, "br label %" + c2)
    irg_add(g, n2_label + ":")
    irg_add(g, "br label %" + t2)
    irg_add(g, t2 + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    rem = irg_new_reg(g)
    irg_add(g, rem + " = sub i64 " + s_len + ", " + pos)
    out = irg_new_reg(g)
    irg_add(g, out + " = load i64, ptr " + out_a)
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + out)
    src = irg_new_reg(g)
    irg_add(g, src + " = getelementptr i8, ptr " + s + ", i64 " + pos)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + src + ", i64 " + rem + ")")
    out2 = irg_new_reg(g)
    irg_add(g, out2 + " = add i64 " + out + ", " + rem)
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + out2)
    irg_add(g, "store i8 0, ptr " + nul)
    irg_add(g, "store ptr " + buf + ", ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load ptr, ptr " + res_a)
    return r
}

public def irg_str_repeat(g: @var IRGen, s: str, n: str) -> str {
    ln = irg_new_reg(g)
    irg_add(g, ln + " = call i64 @strlen(ptr " + s + ")")
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca ptr")
    empty_label = irg_new_label(g, "re.empty")
    do_label = irg_new_label(g, "re.do")
    end_label = irg_new_label(g, "re.end")
    nonpos = irg_new_reg(g)
    irg_add(g, nonpos + " = icmp sle i64 " + n + ", 0")
    irg_add(g, "br i1 " + nonpos + ", label %" + empty_label + ", label %" + do_label)
    irg_add(g, empty_label + ":")
    empty = irg_emit_string_const(g, "")
    irg_add(g, "store ptr " + empty + ", ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, do_label + ":")
    total = irg_new_reg(g)
    irg_add(g, total + " = mul i64 " + ln + ", " + n)
    alloc = irg_new_reg(g)
    irg_add(g, alloc + " = add i64 " + total + ", 1")
    buf = irg_new_reg(g)
    irg_add(g, buf + " = call ptr @malloc(i64 " + alloc + ")")
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    c_label = irg_new_label(g, "re.c")
    b_label = irg_new_label(g, "re.b")
    e_label = irg_new_label(g, "re.e")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + n)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    off = irg_new_reg(g)
    irg_add(g, off + " = mul i64 " + i + ", " + ln)
    dst = irg_new_reg(g)
    irg_add(g, dst + " = getelementptr i8, ptr " + buf + ", i64 " + off)
    mc = irg_new_reg(g)
    irg_add(g, mc + " = call ptr @memcpy(ptr " + dst + ", ptr " + s + ", i64 " + ln + ")")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
    nul = irg_new_reg(g)
    irg_add(g, nul + " = getelementptr i8, ptr " + buf + ", i64 " + total)
    irg_add(g, "store i8 0, ptr " + nul)
    irg_add(g, "store ptr " + buf + ", ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load ptr, ptr " + res_a)
    return r
}

# Split on '\n', strip one trailing '\r' per line, drop the final empty segment.
public def irg_str_lines(g: @var IRGen, s: str) -> str {
    irg_ensure_type(g, "List$str")
    list_a = irg_new_reg(g)
    irg_add(g, list_a + " = alloca %List$str")
    irg_add(g, "store %List$str zeroinitializer, ptr " + list_a)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %List$str, ptr " + list_a + ", i32 0, i32 0")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr %List$str, ptr " + list_a + ", i32 0, i32 2")
    data0 = irg_new_reg(g)
    irg_add(g, data0 + " = call ptr @malloc(i64 32)")
    irg_add(g, "store ptr " + data0 + ", ptr " + data_p)
    irg_add(g, "store i64 4, ptr " + cap_p)
    s_len = irg_new_reg(g)
    irg_add(g, s_len + " = call i64 @strlen(ptr " + s + ")")
    pos_a = irg_new_reg(g)
    irg_add(g, pos_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + pos_a)
    oc = irg_new_label(g, "ln.oc")
    ob = irg_new_label(g, "ln.ob")
    sc = irg_new_label(g, "ln.sc")
    sb = irg_new_label(g, "ln.sb")
    si = irg_new_label(g, "ln.si")
    seg = irg_new_label(g, "ln.seg")
    crc = irg_new_label(g, "ln.cr")
    cray = irg_new_label(g, "ln.cray")
    push = irg_new_label(g, "ln.push")
    adv = irg_new_label(g, "ln.adv")
    oe = irg_new_label(g, "ln.oe")
    irg_add(g, "br label %" + oc)
    irg_add(g, oc + ":")
    pos = irg_new_reg(g)
    irg_add(g, pos + " = load i64, ptr " + pos_a)
    done = irg_new_reg(g)
    irg_add(g, done + " = icmp sge i64 " + pos + ", " + s_len)
    irg_add(g, "br i1 " + done + ", label %" + oe + ", label %" + ob)
    irg_add(g, ob + ":")
    irg_add(g, "br label %" + sc)
    irg_add(g, sc + ":")
    j = irg_new_reg(g)
    irg_add(g, j + " = load i64, ptr " + pos_a)
    # j is reused as the scan cursor via a separate alloca.
    j_a = irg_new_reg(g)
    irg_add(g, j_a + " = alloca i64")
    irg_add(g, "store i64 " + j + ", ptr " + j_a)
    irg_add(g, "br label %" + si)
    irg_add(g, si + ":")
    jj = irg_new_reg(g)
    irg_add(g, jj + " = load i64, ptr " + j_a)
    in_s = irg_new_reg(g)
    irg_add(g, in_s + " = icmp slt i64 " + jj + ", " + s_len)
    irg_add(g, "br i1 " + in_s + ", label %" + sb + ", label %" + seg)
    irg_add(g, sb + ":")
    cp = irg_new_reg(g)
    irg_add(g, cp + " = getelementptr i8, ptr " + s + ", i64 " + jj)
    ch = irg_new_reg(g)
    irg_add(g, ch + " = load i8, ptr " + cp)
    isnl = irg_new_reg(g)
    irg_add(g, isnl + " = icmp eq i8 " + ch + ", 10")
    irg_add(g, "br i1 " + isnl + ", label %" + seg + ", label %" + adv)
    irg_add(g, adv + ":")
    jn = irg_new_reg(g)
    irg_add(g, jn + " = add i64 " + jj + ", 1")
    irg_add(g, "store i64 " + jn + ", ptr " + j_a)
    irg_add(g, "br label %" + si)
    irg_add(g, seg + ":")
    # seg_end = j; strip one '\r' when seg_end > pos.
    se_a = irg_new_reg(g)
    irg_add(g, se_a + " = alloca i64")
    seg_end = irg_new_reg(g)
    irg_add(g, seg_end + " = load i64, ptr " + j_a)
    irg_add(g, "store i64 " + seg_end + ", ptr " + se_a)
    pos2 = irg_new_reg(g)
    irg_add(g, pos2 + " = load i64, ptr " + pos_a)
    gt = irg_new_reg(g)
    irg_add(g, gt + " = icmp sgt i64 " + seg_end + ", " + pos2)
    irg_add(g, "br i1 " + gt + ", label %" + crc + ", label %" + push)
    irg_add(g, crc + ":")
    prev = irg_new_reg(g)
    irg_add(g, prev + " = sub i64 " + seg_end + ", 1")
    pp = irg_new_reg(g)
    irg_add(g, pp + " = getelementptr i8, ptr " + s + ", i64 " + prev)
    pc = irg_new_reg(g)
    irg_add(g, pc + " = load i8, ptr " + pp)
    iscr = irg_new_reg(g)
    irg_add(g, iscr + " = icmp eq i8 " + pc + ", 13")
    irg_add(g, "br i1 " + iscr + ", label %" + cray + ", label %" + push)
    irg_add(g, cray + ":")
    se2 = irg_new_reg(g)
    irg_add(g, se2 + " = sub i64 " + seg_end + ", 1")
    irg_add(g, "store i64 " + se2 + ", ptr " + se_a)
    irg_add(g, "br label %" + push)
    irg_add(g, push + ":")
    pos3 = irg_new_reg(g)
    irg_add(g, pos3 + " = load i64, ptr " + pos_a)
    se3 = irg_new_reg(g)
    irg_add(g, se3 + " = load i64, ptr " + se_a)
    part = irg_str_copy_range(g, s, pos3, se3)
    irg_list_push(g, list_a, "List$str", "str", part)
    # Advance past the newline (or past the end when there was no newline).
    jv = irg_new_reg(g)
    irg_add(g, jv + " = load i64, ptr " + j_a)
    npos = irg_new_reg(g)
    irg_add(g, npos + " = add i64 " + jv + ", 1")
    irg_add(g, "store i64 " + npos + ", ptr " + pos_a)
    irg_add(g, "br label %" + oc)
    irg_add(g, oe + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %List$str, ptr " + list_a)
    return r
}

# ---------------------------------------------------------------------------
# List methods
# ---------------------------------------------------------------------------

# Get the list object pointer.
public def irg_list_ptr(g: @var IRGen, e: Expr) -> str {
    list_name = irg_expr_type_name_ref(g, @e)
    p = ""
    if e.kind == ExprVar() and g.var_alloca.contains(e.name) {
        if g.var_is_ptr.contains(e.name) and g.var_is_ptr.get(e.name) == 1 {
            r = irg_new_reg(g)
            irg_add(g, r + " = load ptr, ptr " + g.var_alloca.get(e.name))
            p = r
        } else {
            p = g.var_alloca.get(e.name)
        }
    } elif e.kind == ExprMember() {
        p = irg_member_ptr(g, e.object.get(0), e.name)
    }
    if p.len() == 0 {
        # temporary list values: materialize (moving e is the last use).
        v = irg_codegen_expr(g, e)
        a = irg_new_reg(g)
        irg_add(g, a + " = alloca %" + list_name)
        irg_add(g, "store %" + list_name + " " + v + ", ptr " + a)
        p = a
    }
    return p
}

public def irg_list_elem_name(list_name: str) -> str {
    return list_name.slice(5, list_name.len())
}

public def irg_codegen_list_method(g: @var IRGen, e: Expr) -> str {
    list_name = irg_expr_type_name(g, e.object.get(0))
    elem = irg_list_elem_name(list_name)
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    irg_ensure_type(g, list_name)
    lp = irg_list_ptr(g, e.object.get(0))
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 2")

    if e.name == "len" {
        r = irg_new_reg(g)
        irg_add(g, r + " = load i64, ptr " + len_p)
        return r
    }
    if e.name == "push" {
        v = irg_codegen_expr(g, e.args.get(0))
        if str_eq(elem_ty, "double") and not str_eq(irg_expr_kind(g, e.args.get(0)), "float") {
            fv = irg_new_reg(g)
            irg_add(g, fv + " = sitofp i64 " + v + " to double")
            v = fv
        }
        irg_list_push(g, lp, list_name, elem, v)
        return "0"
    }
    if e.name == "get" {
        idx = irg_codegen_expr(g, e.args.get(0))
        data = irg_new_reg(g)
        irg_add(g, data + " = load ptr, ptr " + data_p)
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + idx)
        r = irg_new_reg(g)
        irg_add(g, r + " = load " + elem_ty + ", ptr " + ep)
        return r
    }
    if e.name == "set" {
        idx = irg_codegen_expr(g, e.args.get(0))
        v = irg_codegen_expr(g, e.args.get(1))
        if str_eq(elem_ty, "double") and not str_eq(irg_expr_kind(g, e.args.get(1)), "float") {
            fv = irg_new_reg(g)
            irg_add(g, fv + " = sitofp i64 " + v + " to double")
            v = fv
        }
        data = irg_new_reg(g)
        irg_add(g, data + " = load ptr, ptr " + data_p)
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + idx)
        irg_add(g, "store " + elem_ty + " " + v + ", ptr " + ep)
        return "0"
    }
    if e.name == "pop" {
        len = irg_new_reg(g)
        irg_add(g, len + " = load i64, ptr " + len_p)
        idx = irg_new_reg(g)
        irg_add(g, idx + " = sub i64 " + len + ", 1")
        data = irg_new_reg(g)
        irg_add(g, data + " = load ptr, ptr " + data_p)
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + idx)
        r = irg_new_reg(g)
        irg_add(g, r + " = load " + elem_ty + ", ptr " + ep)
        len2 = irg_new_reg(g)
        irg_add(g, len2 + " = sub i64 " + len + ", 1")
        irg_add(g, "store i64 " + len2 + ", ptr " + len_p)
        return r
    }
    if e.name == "contains" {
        v = irg_codegen_expr(g, e.args.get(0))
        return irg_list_contains(g, lp, list_name, elem, v)
    }
    if e.name == "index_of" {
        v = irg_codegen_expr(g, e.args.get(0))
        return irg_list_find_index(g, lp, list_name, elem, v)
    }
    if e.name == "clear" {
        irg_add(g, "store i64 0, ptr " + len_p)
        return "0"
    }
    if e.name == "remove_at" {
        idx = irg_codegen_expr(g, e.args.get(0))
        return irg_list_remove_at(g, lp, list_name, elem, idx)
    }
    if e.name == "remove" {
        v = irg_codegen_expr(g, e.args.get(0))
        idx = irg_list_find_index(g, lp, list_name, elem, v)
        return irg_list_remove_value(g, lp, list_name, elem, idx)
    }
    if e.name == "insert" {
        idx = irg_codegen_expr(g, e.args.get(0))
        v = irg_codegen_expr(g, e.args.get(1))
        if str_eq(elem_ty, "double") and
           not str_eq(irg_expr_kind(g, e.args.get(1)), "float") {
            fv = irg_new_reg(g)
            irg_add(g, fv + " = sitofp i64 " + v + " to double")
            v = fv
        }
        irg_list_insert(g, lp, list_name, elem, idx, v)
        return "0"
    }
    if e.name == "reverse" {
        irg_list_reverse(g, lp, list_name, elem)
        return "0"
    }
    return "0"
}

# Push an element into a List (with growth).
public def irg_list_push(g: @var IRGen, lp: str, list_name: str, elem: str, v: str) {
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 2")
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    cap = irg_new_reg(g)
    irg_add(g, cap + " = load i64, ptr " + cap_p)
    need = irg_new_reg(g)
    irg_add(g, need + " = icmp eq i64 " + len + ", " + cap)
    grow_label = irg_new_label(g, "lp.grow")
    cont_label = irg_new_label(g, "lp.cont")
    irg_add(g, "br i1 " + need + ", label %" + grow_label + ", label %" + cont_label)
    irg_add(g, grow_label + ":")
    zero_cap = irg_new_reg(g)
    irg_add(g, zero_cap + " = icmp eq i64 " + cap + ", 0")
    doubled = irg_new_reg(g)
    irg_add(g, doubled + " = mul i64 " + cap + ", 2")
    new_cap = irg_new_reg(g)
    irg_add(g, new_cap + " = select i1 " + zero_cap + ", i64 4, i64 " + doubled)
    size = irg_list_elem_size(g, elem)
    bytes = irg_new_reg(g)
    irg_add(g, bytes + " = mul i64 " + new_cap + ", " + to_string(size))
    old_data = irg_new_reg(g)
    irg_add(g, old_data + " = load ptr, ptr " + data_p)
    new_data = irg_new_reg(g)
    irg_add(g, new_data + " = call ptr @realloc(ptr " + old_data + ", i64 " + bytes + ")")
    irg_add(g, "store ptr " + new_data + ", ptr " + data_p)
    irg_add(g, "store i64 " + new_cap + ", ptr " + cap_p)
    irg_add(g, "br label %" + cont_label)
    irg_add(g, cont_label + ":")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + len)
    irg_add(g, "store " + elem_ty + " " + v + ", ptr " + ep)
    len2 = irg_new_reg(g)
    irg_add(g, len2 + " = add i64 " + len + ", 1")
    irg_add(g, "store i64 " + len2 + ", ptr " + len_p)
}

# List element size (for growth; over-allocation keeps it safe).
public def irg_list_elem_size(g: @var IRGen, elem: str) -> int {
    ty = irg_elem_llvm_type(g, elem)
    return llvm_type_size(g, ty)
}

# List linear search: index of the first equal element, or -1.
public def irg_list_find_index(g: @var IRGen, lp: str, list_name: str, elem: str, v: str) -> str {
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    idx_a = irg_new_reg(g)
    irg_add(g, idx_a + " = alloca i64")
    irg_add(g, "store i64 -1, ptr " + idx_a)
    c_label = irg_new_label(g, "li.cond")
    b_label = irg_new_label(g, "li.body")
    f_label = irg_new_label(g, "li.found")
    n_label = irg_new_label(g, "li.next")
    e_label = irg_new_label(g, "li.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    m = irg_new_reg(g)
    irg_add(g, m + " = icmp slt i64 " + i + ", " + len)
    irg_add(g, "br i1 " + m + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + i)
    ev = irg_new_reg(g)
    irg_add(g, ev + " = load " + elem_ty + ", ptr " + ep)
    eq = irg_new_reg(g)
    if str_eq(elem_ty, "ptr") {
        sc = irg_new_reg(g)
        irg_add(g, sc + " = call i32 @strcmp(ptr " + ev + ", ptr " + v + ")")
        irg_add(g, eq + " = icmp eq i32 " + sc + ", 0")
    } elif str_eq(elem_ty, "double") {
        irg_add(g, eq + " = fcmp oeq double " + ev + ", " + v)
    } else {
        irg_add(g, eq + " = icmp eq " + elem_ty + " " + ev + ", " + v)
    }
    irg_add(g, "br i1 " + eq + ", label %" + f_label + ", label %" + n_label)
    irg_add(g, f_label + ":")
    irg_add(g, "store i64 " + i + ", ptr " + idx_a)
    irg_add(g, "br label %" + e_label)
    irg_add(g, n_label + ":")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i64, ptr " + idx_a)
    return r
}

public def irg_list_contains(g: @var IRGen, lp: str, list_name: str, elem: str, v: str) -> str {
    idx = irg_list_find_index(g, lp, list_name, elem, v)
    r = irg_new_reg(g)
    irg_add(g, r + " = icmp sge i64 " + idx + ", 0")
    return r
}

# Remove the element at idx (clamped to [0, len-1]); empty lists return a zero value.
public def irg_list_remove_at(g: @var IRGen, lp: str, list_name: str, elem: str, idx: str) -> str {
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca " + elem_ty)
    if str_eq(elem_ty, "ptr") {
        empty = irg_emit_string_const(g, "")
        irg_add(g, "store ptr " + empty + ", ptr " + res_a)
    } else {
        irg_add(g, "store " + elem_ty + " " + irg_zero_value(elem_ty) + ", ptr " + res_a)
    }
    empty_cmp = irg_new_reg(g)
    irg_add(g, empty_cmp + " = icmp eq i64 " + len + ", 0")
    do_label = irg_new_label(g, "lr.do")
    end_label = irg_new_label(g, "lr.end")
    irg_add(g, "br i1 " + empty_cmp + ", label %" + end_label + ", label %" + do_label)
    irg_add(g, do_label + ":")
    neg = irg_new_reg(g)
    irg_add(g, neg + " = icmp slt i64 " + idx + ", 0")
    i0 = irg_new_reg(g)
    irg_add(g, i0 + " = select i1 " + neg + ", i64 0, i64 " + idx)
    lm1 = irg_new_reg(g)
    irg_add(g, lm1 + " = sub i64 " + len + ", 1")
    too_hi = irg_new_reg(g)
    irg_add(g, too_hi + " = icmp sge i64 " + i0 + ", " + len)
    i1 = irg_new_reg(g)
    irg_add(g, i1 + " = select i1 " + too_hi + ", i64 " + lm1 + ", i64 " + i0)
    ep = irg_new_reg(g)
    irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + i1)
    v = irg_new_reg(g)
    irg_add(g, v + " = load " + elem_ty + ", ptr " + ep)
    irg_add(g, "store " + elem_ty + " " + v + ", ptr " + res_a)
    j_a = irg_new_reg(g)
    irg_add(g, j_a + " = alloca i64")
    irg_add(g, "store i64 " + i1 + ", ptr " + j_a)
    c_label = irg_new_label(g, "lr.cond")
    b_label = irg_new_label(g, "lr.body")
    s_label = irg_new_label(g, "lr.shift")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    j = irg_new_reg(g)
    irg_add(g, j + " = load i64, ptr " + j_a)
    nx = irg_new_reg(g)
    irg_add(g, nx + " = add i64 " + j + ", 1")
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + nx + ", " + len)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + s_label)
    irg_add(g, b_label + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + nx)
    sv = irg_new_reg(g)
    irg_add(g, sv + " = load " + elem_ty + ", ptr " + sp)
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + j)
    irg_add(g, "store " + elem_ty + " " + sv + ", ptr " + dp)
    irg_add(g, "store i64 " + nx + ", ptr " + j_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, s_label + ":")
    len2 = irg_new_reg(g)
    irg_add(g, len2 + " = sub i64 " + len + ", 1")
    irg_add(g, "store i64 " + len2 + ", ptr " + len_p)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load " + elem_ty + ", ptr " + res_a)
    return r
}

# Remove a known index and report whether it was present.
public def irg_list_remove_value(g: @var IRGen, lp: str, list_name: str, elem: str, idx: str) -> str {
    res_a = irg_new_reg(g)
    irg_add(g, res_a + " = alloca i1")
    irg_add(g, "store i1 false, ptr " + res_a)
    found = irg_new_reg(g)
    irg_add(g, found + " = icmp sge i64 " + idx + ", 0")
    hit = irg_new_label(g, "lv.hit")
    end_label = irg_new_label(g, "lv.end")
    irg_add(g, "br i1 " + found + ", label %" + hit + ", label %" + end_label)
    irg_add(g, hit + ":")
    irg_list_remove_at(g, lp, list_name, elem, idx)
    irg_add(g, "store i1 true, ptr " + res_a)
    irg_add(g, "br label %" + end_label)
    irg_add(g, end_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load i1, ptr " + res_a)
    return r
}

# Insert at a clamped index, shifting later elements right.
public def irg_list_insert(g: @var IRGen, lp: str, list_name: str, elem: str, idx: str, v: str) {
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    len0 = irg_new_reg(g)
    irg_add(g, len0 + " = load i64, ptr " + len_p)
    neg = irg_new_reg(g)
    irg_add(g, neg + " = icmp slt i64 " + idx + ", 0")
    i0 = irg_new_reg(g)
    irg_add(g, i0 + " = select i1 " + neg + ", i64 0, i64 " + idx)
    too_hi = irg_new_reg(g)
    irg_add(g, too_hi + " = icmp sgt i64 " + i0 + ", " + len0)
    at = irg_new_reg(g)
    irg_add(g, at + " = select i1 " + too_hi + ", i64 " + len0 + ", i64 " + i0)
    irg_list_push(g, lp, list_name, elem, v)
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    j_a = irg_new_reg(g)
    irg_add(g, j_a + " = alloca i64")
    last = irg_new_reg(g)
    irg_add(g, last + " = sub i64 " + len + ", 2")
    irg_add(g, "store i64 " + last + ", ptr " + j_a)
    c_label = irg_new_label(g, "in.cond")
    b_label = irg_new_label(g, "in.body")
    e_label = irg_new_label(g, "in.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    j = irg_new_reg(g)
    irg_add(g, j + " = load i64, ptr " + j_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp sge i64 " + j + ", " + at)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + j)
    sv = irg_new_reg(g)
    irg_add(g, sv + " = load " + elem_ty + ", ptr " + sp)
    nx = irg_new_reg(g)
    irg_add(g, nx + " = add i64 " + j + ", 1")
    dp = irg_new_reg(g)
    irg_add(g, dp + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + nx)
    irg_add(g, "store " + elem_ty + " " + sv + ", ptr " + dp)
    j2 = irg_new_reg(g)
    irg_add(g, j2 + " = sub i64 " + j + ", 1")
    irg_add(g, "store i64 " + j2 + ", ptr " + j_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
    vp = irg_new_reg(g)
    irg_add(g, vp + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + at)
    irg_add(g, "store " + elem_ty + " " + v + ", ptr " + vp)
}

# Reverse in place.
public def irg_list_reverse(g: @var IRGen, lp: str, list_name: str, elem: str) {
    elem_ty = irg_elem_llvm_type(g, elem)
    list_ty = "%" + list_name
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 0")
    len_p = irg_new_reg(g)
    irg_add(g, len_p + " = getelementptr " + list_ty + ", ptr " + lp + ", i32 0, i32 1")
    data = irg_new_reg(g)
    irg_add(g, data + " = load ptr, ptr " + data_p)
    len = irg_new_reg(g)
    irg_add(g, len + " = load i64, ptr " + len_p)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    j_a = irg_new_reg(g)
    irg_add(g, j_a + " = alloca i64")
    j0 = irg_new_reg(g)
    irg_add(g, j0 + " = sub i64 " + len + ", 1")
    irg_add(g, "store i64 " + j0 + ", ptr " + j_a)
    c_label = irg_new_label(g, "rv.cond")
    b_label = irg_new_label(g, "rv.body")
    e_label = irg_new_label(g, "rv.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    j = irg_new_reg(g)
    irg_add(g, j + " = load i64, ptr " + j_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + j)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    pi = irg_new_reg(g)
    irg_add(g, pi + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + i)
    vi = irg_new_reg(g)
    irg_add(g, vi + " = load " + elem_ty + ", ptr " + pi)
    pj = irg_new_reg(g)
    irg_add(g, pj + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + j)
    vj = irg_new_reg(g)
    irg_add(g, vj + " = load " + elem_ty + ", ptr " + pj)
    irg_add(g, "store " + elem_ty + " " + vj + ", ptr " + pi)
    irg_add(g, "store " + elem_ty + " " + vi + ", ptr " + pj)
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    j2 = irg_new_reg(g)
    irg_add(g, j2 + " = sub i64 " + j + ", 1")
    irg_add(g, "store i64 " + j2 + ", ptr " + j_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
}

# ---------------------------------------------------------------------------
# Map methods
# ---------------------------------------------------------------------------

public def irg_map_ptr(g: @var IRGen, e: Expr) -> str {
    map_name = irg_expr_type_name_ref(g, @e)
    p = ""
    if e.kind == ExprVar() and g.var_alloca.contains(e.name) {
        if g.var_is_ptr.contains(e.name) and g.var_is_ptr.get(e.name) == 1 {
            r = irg_new_reg(g)
            irg_add(g, r + " = load ptr, ptr " + g.var_alloca.get(e.name))
            p = r
        } else {
            p = g.var_alloca.get(e.name)
        }
    } elif e.kind == ExprMember() {
        p = irg_member_ptr(g, e.object.get(0), e.name)
    }
    if p.len() == 0 {
        # temporary map values: materialize (moving e is the last use).
        v = irg_codegen_expr(g, e)
        a = irg_new_reg(g)
        irg_add(g, a + " = alloca %" + map_name)
        irg_add(g, "store %" + map_name + " " + v + ", ptr " + a)
        p = a
    }
    return p
}

public def irg_codegen_map_method(g: @var IRGen, e: Expr) -> str {
    map_name = irg_expr_type_name(g, e.object.get(0))
    rest = map_name.slice(4, map_name.len())
    d = str_find(rest, "$")
    key = rest.slice(0, d)
    val = rest.slice(d + 1, rest.len())
    key_ty = irg_elem_llvm_type(g, key)
    val_ty = irg_elem_llvm_type(g, val)
    map_ty = "%" + map_name
    irg_ensure_map_helpers(g, map_name)
    mp = irg_map_ptr(g, e.object.get(0))

    if e.name == "len" {
        count_p = irg_new_reg(g)
        irg_add(g, count_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 4")
        r = irg_new_reg(g)
        irg_add(g, r + " = load i64, ptr " + count_p)
        return r
    }
    if e.name == "contains" {
        k = irg_coerce_elem(g, e.args.get(0), key_ty)
        res = irg_new_reg(g)
        irg_add(g, res + " = call i64 @" + irg_map_helper_sym("find", map_name) +
                  "(ptr " + mp + ", " + key_ty + " " + k + ")")
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp sgt i64 " + res + ", 0")
        return r
    }
    if e.name == "get" {
        k = irg_coerce_elem(g, e.args.get(0), key_ty)
        res = irg_new_reg(g)
        irg_add(g, res + " = call i64 @" + irg_map_helper_sym("find", map_name) +
                  "(ptr " + mp + ", " + key_ty + " " + k + ")")
        found = irg_new_reg(g)
        irg_add(g, found + " = icmp sgt i64 " + res + ", 0")
        hit_label = irg_new_label(g, "mg.hit")
        miss_label = irg_new_label(g, "mg.miss")
        merge_label = irg_new_label(g, "mg.end")
        irg_add(g, "br i1 " + found + ", label %" + hit_label + ", label %" + miss_label)
        irg_add(g, hit_label + ":")
        slot = irg_new_reg(g)
        irg_add(g, slot + " = sub i64 " + res + ", 1")
        buckets_p = irg_new_reg(g)
        irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 2")
        buckets = irg_new_reg(g)
        irg_add(g, buckets + " = load ptr, ptr " + buckets_p)
        bp = irg_new_reg(g)
        irg_add(g, bp + " = getelementptr i64, ptr " + buckets + ", i64 " + slot)
        entry = irg_new_reg(g)
        irg_add(g, entry + " = load i64, ptr " + bp)
        idx = irg_new_reg(g)
        irg_add(g, idx + " = sub i64 " + entry + ", 1")
        vals_p = irg_new_reg(g)
        irg_add(g, vals_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 1")
        vals_data_p = irg_new_reg(g)
        irg_add(g, vals_data_p + " = getelementptr %List$" + val + ", ptr " + vals_p + ", i32 0, i32 0")
        vals_data = irg_new_reg(g)
        irg_add(g, vals_data + " = load ptr, ptr " + vals_data_p)
        vp = irg_new_reg(g)
        irg_add(g, vp + " = getelementptr " + val_ty + ", ptr " + vals_data + ", i64 " + idx)
        hv = irg_new_reg(g)
        irg_add(g, hv + " = load " + val_ty + ", ptr " + vp)
        irg_add(g, "br label %" + merge_label)
        irg_add(g, miss_label + ":")
        irg_add(g, "br label %" + merge_label)
        irg_add(g, merge_label + ":")
        zero = irg_zero_value(val_ty)
        if str_eq(val_ty, "ptr") {
            zero = irg_emit_string_const(g, "")
        }
        r = irg_new_reg(g)
        irg_add(g, r + " = phi " + val_ty + " [ " + hv + ", %" + hit_label + " ], [ " +
                  zero + ", %" + miss_label + " ]")
        return r
    }
    if e.name == "put" {
        k = irg_coerce_elem(g, e.args.get(0), key_ty)
        v = irg_coerce_elem(g, e.args.get(1), val_ty)
        irg_add(g, "call void @" + irg_map_helper_sym("put", map_name) +
                  "(ptr " + mp + ", " + key_ty + " " + k + ", " + val_ty + " " + v + ")")
        return "0"
    }
    if e.name == "remove" {
        k = irg_coerce_elem(g, e.args.get(0), key_ty)
        r = irg_new_reg(g)
        irg_add(g, r + " = call i1 @" + irg_map_helper_sym("remove", map_name) +
                  "(ptr " + mp + ", " + key_ty + " " + k + ")")
        return r
    }
    if e.name == "keys" {
        return irg_codegen_map_collect(g, mp, map_name, key, "keys")
    }
    if e.name == "values" {
        return irg_codegen_map_collect(g, mp, map_name, val, "values")
    }
    return "0"
}

# Generate a value and promote int -> float when the container slot is double.
public def irg_coerce_elem(g: @var IRGen, expr: Expr, ty: str) -> str {
    k = irg_expr_kind_ref(g, @expr)
    v = irg_codegen_expr(g, expr)
    if str_eq(ty, "double") and not str_eq(k, "float") {
        fv = irg_new_reg(g)
        irg_add(g, fv + " = sitofp i64 " + v + " to double")
        return fv
    }
    return v
}

public def irg_codegen_map_collect(g: @var IRGen, mp: str, map_name: str, elem: str,
                                   which: str) -> str {
    map_ty = "%" + map_name
    elem_ty = irg_elem_llvm_type(g, elem)
    list_name = "List$" + elem
    irg_ensure_type(g, list_name)
    list_a = irg_new_reg(g)
    irg_add(g, list_a + " = alloca %" + list_name)
    irg_add(g, "store %" + list_name + " zeroinitializer, ptr " + list_a)
    count_p = irg_new_reg(g)
    irg_add(g, count_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 4")
    count = irg_new_reg(g)
    irg_add(g, count + " = load i64, ptr " + count_p)
    cap = irg_new_reg(g)
    irg_add(g, cap + " = icmp slt i64 " + count + ", 4")
    cap2 = irg_new_reg(g)
    irg_add(g, cap2 + " = select i1 " + cap + ", i64 4, i64 " + count)
    size = irg_list_elem_size(g, elem)
    bytes = irg_new_reg(g)
    irg_add(g, bytes + " = mul i64 " + cap2 + ", " + to_string(size))
    data = irg_new_reg(g)
    irg_add(g, data + " = call ptr @malloc(i64 " + bytes + ")")
    data_p = irg_new_reg(g)
    irg_add(g, data_p + " = getelementptr %" + list_name + ", ptr " + list_a + ", i32 0, i32 0")
    cap_p = irg_new_reg(g)
    irg_add(g, cap_p + " = getelementptr %" + list_name + ", ptr " + list_a + ", i32 0, i32 2")
    irg_add(g, "store ptr " + data + ", ptr " + data_p)
    irg_add(g, "store i64 " + cap2 + ", ptr " + cap_p)

    buckets_p = irg_new_reg(g)
    irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 2")
    nb_p = irg_new_reg(g)
    irg_add(g, nb_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 3")
    buckets = irg_new_reg(g)
    irg_add(g, buckets + " = load ptr, ptr " + buckets_p)
    nb = irg_new_reg(g)
    irg_add(g, nb + " = load i64, ptr " + nb_p)
    src_p = irg_new_reg(g)
    if str_eq(which, "keys") {
        irg_add(g, src_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 0")
    } else {
        irg_add(g, src_p + " = getelementptr " + map_ty + ", ptr " + mp + ", i32 0, i32 1")
    }
    src_data_p = irg_new_reg(g)
    irg_add(g, src_data_p + " = getelementptr %List$" + elem + ", ptr " + src_p + ", i32 0, i32 0")
    src_data = irg_new_reg(g)
    irg_add(g, src_data + " = load ptr, ptr " + src_data_p)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    c_label = irg_new_label(g, "mc.cond")
    b_label = irg_new_label(g, "mc.body")
    add_label = irg_new_label(g, "mc.add")
    n_label = irg_new_label(g, "mc.next")
    e_label = irg_new_label(g, "mc.end")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + nb)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + e_label)
    irg_add(g, b_label + ":")
    bp = irg_new_reg(g)
    irg_add(g, bp + " = getelementptr i64, ptr " + buckets + ", i64 " + i)
    entry = irg_new_reg(g)
    irg_add(g, entry + " = load i64, ptr " + bp)
    live = irg_new_reg(g)
    irg_add(g, live + " = icmp sgt i64 " + entry + ", 0")
    irg_add(g, "br i1 " + live + ", label %" + add_label + ", label %" + n_label)
    irg_add(g, add_label + ":")
    idx = irg_new_reg(g)
    irg_add(g, idx + " = sub i64 " + entry + ", 1")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = getelementptr " + elem_ty + ", ptr " + src_data + ", i64 " + idx)
    sv = irg_new_reg(g)
    irg_add(g, sv + " = load " + elem_ty + ", ptr " + sp)
    irg_list_push(g, list_a, list_name, elem, sv)
    irg_add(g, "br label %" + n_label)
    irg_add(g, n_label + ":")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, e_label + ":")
    r = irg_new_reg(g)
    irg_add(g, r + " = load %" + list_name + ", ptr " + list_a)
    return r
}

public def irg_map_helper_sym(prefix: str, map_name: str) -> str {
    return "rgc_map_" + prefix + "_" + map_name
}

public def irg_map_hash_kind(key: str) -> str {
    kd = irg_elem_kind(key)
    if str_eq(kd, "str") {
        return "str"
    }
    if str_eq(kd, "float") {
        return "float"
    }
    return "i64"
}

public def irg_ensure_map_helpers(g: @var IRGen, map_name: str) {
    irg_ensure_type(g, map_name)
    if not g.map_helpers.contains(map_name) {
        g.map_helpers.push(map_name)
    }
    rest = map_name.slice(4, map_name.len())
    d = str_find(rest, "$")
    key = rest.slice(0, d)
    hk = irg_map_hash_kind(key)
    if not g.map_hash_kinds.contains(hk) {
        g.map_hash_kinds.push(hk)
    }
}

def irg_helper_begin(g: @var IRGen, sym: str) {
    g.reg = 0
    g.label = 0
    g.in_fn = 0
    g.cur_fn = sym
}

public def irg_map_hash_call(g: @var IRGen, key: str, key_ty: str, k: str) -> str {
    kd = irg_elem_kind(key)
    if str_eq(kd, "str") {
        r = irg_new_reg(g)
        irg_add(g, r + " = call i64 @rgc_map_hash_str(ptr " + k + ")")
        return r
    }
    if str_eq(kd, "float") {
        r = irg_new_reg(g)
        irg_add(g, r + " = call i64 @rgc_map_hash_float(double " + k + ")")
        return r
    }
    kv = k
    if str_eq(key_ty, "i1") {
        z = irg_new_reg(g)
        irg_add(g, z + " = zext i1 " + k + " to i64")
        kv = z
    }
    r = irg_new_reg(g)
    irg_add(g, r + " = call i64 @rgc_map_hash_i64(i64 " + kv + ")")
    return r
}

public def irg_emit_map_hash(g: @var IRGen, kind: str) {
    key = "map_hash:" + kind
    if g.emitted_externs.contains(key) {
        return
    }
    g.emitted_externs.put(key, 1)
    irg_helper_begin(g, "rgc_map_hash_" + kind)
    if str_eq(kind, "str") {
        irg_add(g, "define i64 @rgc_map_hash_str(ptr %k) {")
        irg_add(g, "entry:")
        h_a = irg_new_reg(g)
        irg_add(g, h_a + " = alloca i64")
        irg_add(g, "store i64 -3750763034362895579, ptr " + h_a)
        p_a = irg_new_reg(g)
        irg_add(g, p_a + " = alloca ptr")
        irg_add(g, "store ptr %k, ptr " + p_a)
        c_label = irg_new_label(g, "hh.cond")
        b_label = irg_new_label(g, "hh.body")
        e_label = irg_new_label(g, "hh.end")
        irg_add(g, "br label %" + c_label)
        irg_add(g, c_label + ":")
        p = irg_new_reg(g)
        irg_add(g, p + " = load ptr, ptr " + p_a)
        ch = irg_new_reg(g)
        irg_add(g, ch + " = load i8, ptr " + p)
        done = irg_new_reg(g)
        irg_add(g, done + " = icmp eq i8 " + ch + ", 0")
        irg_add(g, "br i1 " + done + ", label %" + e_label + ", label %" + b_label)
        irg_add(g, b_label + ":")
        z = irg_new_reg(g)
        irg_add(g, z + " = zext i8 " + ch + " to i64")
        h = irg_new_reg(g)
        irg_add(g, h + " = load i64, ptr " + h_a)
        h2 = irg_new_reg(g)
        irg_add(g, h2 + " = xor i64 " + h + ", " + z)
        h3 = irg_new_reg(g)
        irg_add(g, h3 + " = mul i64 " + h2 + ", 1099511628211")
        irg_add(g, "store i64 " + h3 + ", ptr " + h_a)
        p2 = irg_new_reg(g)
        irg_add(g, p2 + " = getelementptr i8, ptr " + p + ", i64 1")
        irg_add(g, "store ptr " + p2 + ", ptr " + p_a)
        irg_add(g, "br label %" + c_label)
        irg_add(g, e_label + ":")
        r = irg_new_reg(g)
        irg_add(g, r + " = load i64, ptr " + h_a)
        irg_add(g, "ret i64 " + r)
        irg_add(g, "}")
        return
    }
    if str_eq(kind, "float") {
        irg_add(g, "define i64 @rgc_map_hash_float(double %k) {")
        irg_add(g, "entry:")
        bits = irg_new_reg(g)
        irg_add(g, bits + " = bitcast double %k to i64")
        irg_emit_map_mix(g, bits)
        return
    }
    irg_add(g, "define i64 @rgc_map_hash_i64(i64 %k) {")
    irg_add(g, "entry:")
    irg_emit_map_mix(g, "%k")
}

# Shared splitmix64 finalizer; leaves the result in `ret` and closes the function.
def irg_emit_map_mix(g: @var IRGen, x: str) {
    s1 = irg_new_reg(g)
    irg_add(g, s1 + " = lshr i64 " + x + ", 30")
    x1 = irg_new_reg(g)
    irg_add(g, x1 + " = xor i64 " + x + ", " + s1)
    m1 = irg_new_reg(g)
    irg_add(g, m1 + " = mul i64 " + x1 + ", -4658895280553007687")
    s2 = irg_new_reg(g)
    irg_add(g, s2 + " = lshr i64 " + m1 + ", 27")
    x2 = irg_new_reg(g)
    irg_add(g, x2 + " = xor i64 " + m1 + ", " + s2)
    m2 = irg_new_reg(g)
    irg_add(g, m2 + " = mul i64 " + x2 + ", -7723592293110705685")
    s3 = irg_new_reg(g)
    irg_add(g, s3 + " = lshr i64 " + m2 + ", 31")
    x3 = irg_new_reg(g)
    irg_add(g, x3 + " = xor i64 " + m2 + ", " + s3)
    irg_add(g, "ret i64 " + x3)
    irg_add(g, "}")
}

public def irg_emit_map_helpers(g: @var IRGen) {
    i = 0
    while i < g.map_hash_kinds.len() {
        irg_emit_map_hash(g, g.map_hash_kinds.get(i))
        i = i + 1
    }
    i = 0
    while i < g.map_helpers.len() {
        map_name = g.map_helpers.get(i)
        rest = map_name.slice(4, map_name.len())
        d = str_find(rest, "$")
        key = rest.slice(0, d)
        val = rest.slice(d + 1, rest.len())
        irg_emit_map_find(g, map_name, key)
        irg_emit_map_rehash(g, map_name, key)
        irg_emit_map_put(g, map_name, key, val)
        irg_emit_map_remove(g, map_name, key)
        i = i + 1
    }
}

public def irg_emit_map_find(g: @var IRGen, map_name: str, key: str) {
    key_ty = irg_elem_llvm_type(g, key)
    map_ty = "%" + map_name
    sym = "@" + irg_map_helper_sym("find", map_name)
    irg_helper_begin(g, sym)
    irg_add(g, "define i64 " + sym + "(ptr %m, " + key_ty + " %k) {")
    irg_add(g, "entry:")
    nb_p = irg_new_reg(g)
    irg_add(g, nb_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 3")
    nb = irg_new_reg(g)
    irg_add(g, nb + " = load i64, ptr " + nb_p)
    zero = irg_new_reg(g)
    irg_add(g, zero + " = icmp eq i64 " + nb + ", 0")
    probe_label = irg_new_label(g, "mfd.probe")
    ret0_label = irg_new_label(g, "mfd.zero")
    irg_add(g, "br i1 " + zero + ", label %" + ret0_label + ", label %" + probe_label)
    irg_add(g, ret0_label + ":")
    irg_add(g, "ret i64 0")

    irg_add(g, probe_label + ":")
    h = irg_map_hash_call(g, key, key_ty, "%k")
    mask = irg_new_reg(g)
    irg_add(g, mask + " = sub i64 " + nb + ", 1")
    buckets_p = irg_new_reg(g)
    irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 2")
    buckets = irg_new_reg(g)
    irg_add(g, buckets + " = load ptr, ptr " + buckets_p)
    keys_p = irg_new_reg(g)
    irg_add(g, keys_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 0")
    keys_data_p = irg_new_reg(g)
    irg_add(g, keys_data_p + " = getelementptr %List$" + key + ", ptr " + keys_p + ", i32 0, i32 0")
    keys_data = irg_new_reg(g)
    irg_add(g, keys_data + " = load ptr, ptr " + keys_data_p)
    slot_a = irg_new_reg(g)
    irg_add(g, slot_a + " = alloca i64")
    slot0 = irg_new_reg(g)
    irg_add(g, slot0 + " = and i64 " + h + ", " + mask)
    irg_add(g, "store i64 " + slot0 + ", ptr " + slot_a)
    free_a = irg_new_reg(g)
    irg_add(g, free_a + " = alloca i64")
    irg_add(g, "store i64 -1, ptr " + free_a)
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)

    c_label = irg_new_label(g, "mfd.cond")
    b_label = irg_new_label(g, "mfd.body")
    has_label = irg_new_label(g, "mfd.has")
    tomb_label = irg_new_label(g, "mfd.tomb")
    setf_label = irg_new_label(g, "mfd.setfree")
    cmp_label = irg_new_label(g, "mfd.cmp")
    hit_label = irg_new_label(g, "mfd.hit")
    next_label = irg_new_label(g, "mfd.next")
    nf_label = irg_new_label(g, "mfd.notfound")
    uf_label = irg_new_label(g, "mfd.usefree")
    ue_label = irg_new_label(g, "mfd.useempty")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + nb)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + nf_label)
    irg_add(g, b_label + ":")
    slot = irg_new_reg(g)
    irg_add(g, slot + " = load i64, ptr " + slot_a)
    bp = irg_new_reg(g)
    irg_add(g, bp + " = getelementptr i64, ptr " + buckets + ", i64 " + slot)
    entry = irg_new_reg(g)
    irg_add(g, entry + " = load i64, ptr " + bp)
    isempty = irg_new_reg(g)
    irg_add(g, isempty + " = icmp eq i64 " + entry + ", 0")
    irg_add(g, "br i1 " + isempty + ", label %" + nf_label + ", label %" + has_label)
    irg_add(g, has_label + ":")
    isdel = irg_new_reg(g)
    irg_add(g, isdel + " = icmp eq i64 " + entry + ", -1")
    irg_add(g, "br i1 " + isdel + ", label %" + tomb_label + ", label %" + cmp_label)
    irg_add(g, tomb_label + ":")
    fs = irg_new_reg(g)
    irg_add(g, fs + " = load i64, ptr " + free_a)
    first = irg_new_reg(g)
    irg_add(g, first + " = icmp slt i64 " + fs + ", 0")
    irg_add(g, "br i1 " + first + ", label %" + setf_label + ", label %" + next_label)
    irg_add(g, setf_label + ":")
    irg_add(g, "store i64 " + slot + ", ptr " + free_a)
    irg_add(g, "br label %" + next_label)
    irg_add(g, cmp_label + ":")
    idx = irg_new_reg(g)
    irg_add(g, idx + " = sub i64 " + entry + ", 1")
    kp = irg_new_reg(g)
    irg_add(g, kp + " = getelementptr " + key_ty + ", ptr " + keys_data + ", i64 " + idx)
    kv = irg_new_reg(g)
    irg_add(g, kv + " = load " + key_ty + ", ptr " + kp)
    eq = irg_new_reg(g)
    if str_eq(key_ty, "ptr") {
        kc = irg_new_reg(g)
        irg_add(g, kc + " = call i32 @strcmp(ptr " + kv + ", ptr %k)")
        irg_add(g, eq + " = icmp eq i32 " + kc + ", 0")
    } elif str_eq(key_ty, "double") {
        irg_add(g, eq + " = fcmp oeq double " + kv + ", %k")
    } else {
        irg_add(g, eq + " = icmp eq " + key_ty + " " + kv + ", %k")
    }
    irg_add(g, "br i1 " + eq + ", label %" + hit_label + ", label %" + next_label)
    irg_add(g, hit_label + ":")
    hp = irg_new_reg(g)
    irg_add(g, hp + " = add i64 " + slot + ", 1")
    irg_add(g, "ret i64 " + hp)
    irg_add(g, next_label + ":")
    slot2 = irg_new_reg(g)
    irg_add(g, slot2 + " = add i64 " + slot + ", 1")
    slot3 = irg_new_reg(g)
    irg_add(g, slot3 + " = and i64 " + slot2 + ", " + mask)
    irg_add(g, "store i64 " + slot3 + ", ptr " + slot_a)
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)

    irg_add(g, nf_label + ":")
    fs2 = irg_new_reg(g)
    irg_add(g, fs2 + " = load i64, ptr " + free_a)
    hasfree = irg_new_reg(g)
    irg_add(g, hasfree + " = icmp sge i64 " + fs2 + ", 0")
    irg_add(g, "br i1 " + hasfree + ", label %" + uf_label + ", label %" + ue_label)
    irg_add(g, uf_label + ":")
    n1 = irg_new_reg(g)
    irg_add(g, n1 + " = sub i64 0, " + fs2)
    n2 = irg_new_reg(g)
    irg_add(g, n2 + " = sub i64 " + n1 + ", 1")
    irg_add(g, "ret i64 " + n2)
    irg_add(g, ue_label + ":")
    cs = irg_new_reg(g)
    irg_add(g, cs + " = load i64, ptr " + slot_a)
    n3 = irg_new_reg(g)
    irg_add(g, n3 + " = sub i64 0, " + cs)
    n4 = irg_new_reg(g)
    irg_add(g, n4 + " = sub i64 " + n3 + ", 1")
    irg_add(g, "ret i64 " + n4)
    irg_add(g, "}")
}

public def irg_emit_map_rehash(g: @var IRGen, map_name: str, key: str) {
    key_ty = irg_elem_llvm_type(g, key)
    map_ty = "%" + map_name
    sym = "@" + irg_map_helper_sym("rehash", map_name)
    irg_helper_begin(g, sym)
    irg_add(g, "define void " + sym + "(ptr %m, i64 %new_n) {")
    irg_add(g, "entry:")
    buckets_p = irg_new_reg(g)
    irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 2")
    old = irg_new_reg(g)
    irg_add(g, old + " = load ptr, ptr " + buckets_p)
    nb_p = irg_new_reg(g)
    irg_add(g, nb_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 3")
    old_n = irg_new_reg(g)
    irg_add(g, old_n + " = load i64, ptr " + nb_p)
    bytes = irg_new_reg(g)
    irg_add(g, bytes + " = mul i64 %new_n, 8")
    new = irg_new_reg(g)
    irg_add(g, new + " = call ptr @malloc(i64 " + bytes + ")")
    irg_add(g, "call void @memset(ptr " + new + ", i32 0, i64 " + bytes + ")")
    irg_add(g, "store ptr " + new + ", ptr " + buckets_p)
    irg_add(g, "store i64 %new_n, ptr " + nb_p)
    count_p = irg_new_reg(g)
    irg_add(g, count_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 4")
    count = irg_new_reg(g)
    irg_add(g, count + " = load i64, ptr " + count_p)
    used_p = irg_new_reg(g)
    irg_add(g, used_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 5")
    irg_add(g, "store i64 " + count + ", ptr " + used_p)
    keys_p = irg_new_reg(g)
    irg_add(g, keys_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 0")
    keys_data_p = irg_new_reg(g)
    irg_add(g, keys_data_p + " = getelementptr %List$" + key + ", ptr " + keys_p + ", i32 0, i32 0")
    keys_data = irg_new_reg(g)
    irg_add(g, keys_data + " = load ptr, ptr " + keys_data_p)
    mask = irg_new_reg(g)
    irg_add(g, mask + " = sub i64 %new_n, 1")
    slot_a = irg_new_reg(g)
    irg_add(g, slot_a + " = alloca i64")
    i_a = irg_new_reg(g)
    irg_add(g, i_a + " = alloca i64")
    irg_add(g, "store i64 0, ptr " + i_a)
    c_label = irg_new_label(g, "mrh.cond")
    b_label = irg_new_label(g, "mrh.body")
    ins_label = irg_new_label(g, "mrh.ins")
    p_label = irg_new_label(g, "mrh.probe")
    pn_label = irg_new_label(g, "mrh.pnext")
    place_label = irg_new_label(g, "mrh.place")
    next_label = irg_new_label(g, "mrh.next")
    done_label = irg_new_label(g, "mrh.done")
    irg_add(g, "br label %" + c_label)
    irg_add(g, c_label + ":")
    i = irg_new_reg(g)
    irg_add(g, i + " = load i64, ptr " + i_a)
    more = irg_new_reg(g)
    irg_add(g, more + " = icmp slt i64 " + i + ", " + old_n)
    irg_add(g, "br i1 " + more + ", label %" + b_label + ", label %" + done_label)
    irg_add(g, b_label + ":")
    op = irg_new_reg(g)
    irg_add(g, op + " = getelementptr i64, ptr " + old + ", i64 " + i)
    entry = irg_new_reg(g)
    irg_add(g, entry + " = load i64, ptr " + op)
    live = irg_new_reg(g)
    irg_add(g, live + " = icmp sgt i64 " + entry + ", 0")
    irg_add(g, "br i1 " + live + ", label %" + ins_label + ", label %" + next_label)
    irg_add(g, ins_label + ":")
    idx = irg_new_reg(g)
    irg_add(g, idx + " = sub i64 " + entry + ", 1")
    kp = irg_new_reg(g)
    irg_add(g, kp + " = getelementptr " + key_ty + ", ptr " + keys_data + ", i64 " + idx)
    kv = irg_new_reg(g)
    irg_add(g, kv + " = load " + key_ty + ", ptr " + kp)
    h = irg_map_hash_call(g, key, key_ty, kv)
    s0 = irg_new_reg(g)
    irg_add(g, s0 + " = and i64 " + h + ", " + mask)
    irg_add(g, "store i64 " + s0 + ", ptr " + slot_a)
    irg_add(g, "br label %" + p_label)
    irg_add(g, p_label + ":")
    sp = irg_new_reg(g)
    irg_add(g, sp + " = load i64, ptr " + slot_a)
    bp = irg_new_reg(g)
    irg_add(g, bp + " = getelementptr i64, ptr " + new + ", i64 " + sp)
    cur = irg_new_reg(g)
    irg_add(g, cur + " = load i64, ptr " + bp)
    empty = irg_new_reg(g)
    irg_add(g, empty + " = icmp eq i64 " + cur + ", 0")
    irg_add(g, "br i1 " + empty + ", label %" + place_label + ", label %" + pn_label)
    irg_add(g, pn_label + ":")
    sp2 = irg_new_reg(g)
    irg_add(g, sp2 + " = add i64 " + sp + ", 1")
    sp3 = irg_new_reg(g)
    irg_add(g, sp3 + " = and i64 " + sp2 + ", " + mask)
    irg_add(g, "store i64 " + sp3 + ", ptr " + slot_a)
    irg_add(g, "br label %" + p_label)
    irg_add(g, place_label + ":")
    irg_add(g, "store i64 " + entry + ", ptr " + bp)
    irg_add(g, "br label %" + next_label)
    irg_add(g, next_label + ":")
    i2 = irg_new_reg(g)
    irg_add(g, i2 + " = add i64 " + i + ", 1")
    irg_add(g, "store i64 " + i2 + ", ptr " + i_a)
    irg_add(g, "br label %" + c_label)
    irg_add(g, done_label + ":")
    irg_add(g, "call void @free(ptr " + old + ")")
    irg_add(g, "ret void")
    irg_add(g, "}")
}

public def irg_emit_map_put(g: @var IRGen, map_name: str, key: str, val: str) {
    key_ty = irg_elem_llvm_type(g, key)
    val_ty = irg_elem_llvm_type(g, val)
    map_ty = "%" + map_name
    find_sym = "@" + irg_map_helper_sym("find", map_name)
    rehash_sym = "@" + irg_map_helper_sym("rehash", map_name)
    sym = "@" + irg_map_helper_sym("put", map_name)
    irg_helper_begin(g, sym)
    irg_add(g, "define void " + sym + "(ptr %m, " + key_ty + " %k, " + val_ty + " %v) {")
    irg_add(g, "entry:")
    nb_p = irg_new_reg(g)
    irg_add(g, nb_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 3")
    buckets_p = irg_new_reg(g)
    irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 2")
    count_p = irg_new_reg(g)
    irg_add(g, count_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 4")
    used_p = irg_new_reg(g)
    irg_add(g, used_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 5")
    nb = irg_new_reg(g)
    irg_add(g, nb + " = load i64, ptr " + nb_p)
    init_needed = irg_new_reg(g)
    irg_add(g, init_needed + " = icmp eq i64 " + nb + ", 0")
    init_label = irg_new_label(g, "mpu.init")
    check_label = irg_new_label(g, "mpu.check")
    irg_add(g, "br i1 " + init_needed + ", label %" + init_label + ", label %" + check_label)
    irg_add(g, init_label + ":")
    b = irg_new_reg(g)
    irg_add(g, b + " = call ptr @malloc(i64 64)")
    irg_add(g, "call void @memset(ptr " + b + ", i32 0, i64 64)")
    irg_add(g, "store ptr " + b + ", ptr " + buckets_p)
    irg_add(g, "store i64 8, ptr " + nb_p)
    irg_add(g, "store i64 0, ptr " + count_p)
    irg_add(g, "store i64 0, ptr " + used_p)
    irg_add(g, "br label %" + check_label)
    irg_add(g, check_label + ":")
    nb2 = irg_new_reg(g)
    irg_add(g, nb2 + " = load i64, ptr " + nb_p)
    used = irg_new_reg(g)
    irg_add(g, used + " = load i64, ptr " + used_p)
    u1 = irg_new_reg(g)
    irg_add(g, u1 + " = add i64 " + used + ", 1")
    lhs = irg_new_reg(g)
    irg_add(g, lhs + " = mul i64 " + u1 + ", 4")
    rhs = irg_new_reg(g)
    irg_add(g, rhs + " = mul i64 " + nb2 + ", 3")
    need = irg_new_reg(g)
    irg_add(g, need + " = icmp sge i64 " + lhs + ", " + rhs)
    grow_label = irg_new_label(g, "mpu.grow")
    lookup_label = irg_new_label(g, "mpu.lookup")
    irg_add(g, "br i1 " + need + ", label %" + grow_label + ", label %" + lookup_label)
    irg_add(g, grow_label + ":")
    nb3 = irg_new_reg(g)
    irg_add(g, nb3 + " = mul i64 " + nb2 + ", 2")
    irg_add(g, "call void " + rehash_sym + "(ptr %m, i64 " + nb3 + ")")
    irg_add(g, "br label %" + lookup_label)
    irg_add(g, lookup_label + ":")
    res = irg_new_reg(g)
    irg_add(g, res + " = call i64 " + find_sym + "(ptr %m, " + key_ty + " %k)")
    found = irg_new_reg(g)
    irg_add(g, found + " = icmp sgt i64 " + res + ", 0")
    upd_label = irg_new_label(g, "mpu.upd")
    ins_label = irg_new_label(g, "mpu.ins")
    done_label = irg_new_label(g, "mpu.done")
    irg_add(g, "br i1 " + found + ", label %" + upd_label + ", label %" + ins_label)
    irg_add(g, upd_label + ":")
    slot = irg_new_reg(g)
    irg_add(g, slot + " = sub i64 " + res + ", 1")
    buckets = irg_new_reg(g)
    irg_add(g, buckets + " = load ptr, ptr " + buckets_p)
    bp = irg_new_reg(g)
    irg_add(g, bp + " = getelementptr i64, ptr " + buckets + ", i64 " + slot)
    entry = irg_new_reg(g)
    irg_add(g, entry + " = load i64, ptr " + bp)
    idx = irg_new_reg(g)
    irg_add(g, idx + " = sub i64 " + entry + ", 1")
    vals_p = irg_new_reg(g)
    irg_add(g, vals_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 1")
    vals_data_p = irg_new_reg(g)
    irg_add(g, vals_data_p + " = getelementptr %List$" + val + ", ptr " + vals_p + ", i32 0, i32 0")
    vals_data = irg_new_reg(g)
    irg_add(g, vals_data + " = load ptr, ptr " + vals_data_p)
    vp = irg_new_reg(g)
    irg_add(g, vp + " = getelementptr " + val_ty + ", ptr " + vals_data + ", i64 " + idx)
    irg_add(g, "store " + val_ty + " %v, ptr " + vp)
    irg_add(g, "br label %" + done_label)
    irg_add(g, ins_label + ":")
    no_table = irg_new_reg(g)
    irg_add(g, no_table + " = icmp eq i64 " + res + ", 0")
    ins2_label = irg_new_label(g, "mpu.ins2")
    irg_add(g, "br i1 " + no_table + ", label %" + done_label + ", label %" + ins2_label)
    irg_add(g, ins2_label + ":")
    neg = irg_new_reg(g)
    irg_add(g, neg + " = sub i64 0, " + res)
    slot2 = irg_new_reg(g)
    irg_add(g, slot2 + " = sub i64 " + neg + ", 1")
    keys_p = irg_new_reg(g)
    irg_add(g, keys_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 0")
    vals_p2 = irg_new_reg(g)
    irg_add(g, vals_p2 + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 1")
    irg_list_push(g, keys_p, "List$" + key, key, "%k")
    irg_list_push(g, vals_p2, "List$" + val, val, "%v")
    klen_p = irg_new_reg(g)
    irg_add(g, klen_p + " = getelementptr %List$" + key + ", ptr " + keys_p + ", i32 0, i32 1")
    klen = irg_new_reg(g)
    irg_add(g, klen + " = load i64, ptr " + klen_p)
    buckets2 = irg_new_reg(g)
    irg_add(g, buckets2 + " = load ptr, ptr " + buckets_p)
    bp2 = irg_new_reg(g)
    irg_add(g, bp2 + " = getelementptr i64, ptr " + buckets2 + ", i64 " + slot2)
    old = irg_new_reg(g)
    irg_add(g, old + " = load i64, ptr " + bp2)
    irg_add(g, "store i64 " + klen + ", ptr " + bp2)
    count2 = irg_new_reg(g)
    irg_add(g, count2 + " = load i64, ptr " + count_p)
    count3 = irg_new_reg(g)
    irg_add(g, count3 + " = add i64 " + count2 + ", 1")
    irg_add(g, "store i64 " + count3 + ", ptr " + count_p)
    was_empty = irg_new_reg(g)
    irg_add(g, was_empty + " = icmp eq i64 " + old + ", 0")
    bump_label = irg_new_label(g, "mpu.bump")
    irg_add(g, "br i1 " + was_empty + ", label %" + bump_label + ", label %" + done_label)
    irg_add(g, bump_label + ":")
    used2 = irg_new_reg(g)
    irg_add(g, used2 + " = load i64, ptr " + used_p)
    used3 = irg_new_reg(g)
    irg_add(g, used3 + " = add i64 " + used2 + ", 1")
    irg_add(g, "store i64 " + used3 + ", ptr " + used_p)
    irg_add(g, "br label %" + done_label)
    irg_add(g, done_label + ":")
    irg_add(g, "ret void")
    irg_add(g, "}")
}

public def irg_emit_map_remove(g: @var IRGen, map_name: str, key: str) {
    key_ty = irg_elem_llvm_type(g, key)
    map_ty = "%" + map_name
    find_sym = "@" + irg_map_helper_sym("find", map_name)
    sym = "@" + irg_map_helper_sym("remove", map_name)
    irg_helper_begin(g, sym)
    irg_add(g, "define i1 " + sym + "(ptr %m, " + key_ty + " %k) {")
    irg_add(g, "entry:")
    res = irg_new_reg(g)
    irg_add(g, res + " = call i64 " + find_sym + "(ptr %m, " + key_ty + " %k)")
    found = irg_new_reg(g)
    irg_add(g, found + " = icmp sgt i64 " + res + ", 0")
    hit_label = irg_new_label(g, "mrm.hit")
    miss_label = irg_new_label(g, "mrm.miss")
    irg_add(g, "br i1 " + found + ", label %" + hit_label + ", label %" + miss_label)
    irg_add(g, hit_label + ":")
    slot = irg_new_reg(g)
    irg_add(g, slot + " = sub i64 " + res + ", 1")
    buckets_p = irg_new_reg(g)
    irg_add(g, buckets_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 2")
    buckets = irg_new_reg(g)
    irg_add(g, buckets + " = load ptr, ptr " + buckets_p)
    bp = irg_new_reg(g)
    irg_add(g, bp + " = getelementptr i64, ptr " + buckets + ", i64 " + slot)
    irg_add(g, "store i64 -1, ptr " + bp)
    count_p = irg_new_reg(g)
    irg_add(g, count_p + " = getelementptr " + map_ty + ", ptr %m, i32 0, i32 4")
    count = irg_new_reg(g)
    irg_add(g, count + " = load i64, ptr " + count_p)
    count2 = irg_new_reg(g)
    irg_add(g, count2 + " = sub i64 " + count + ", 1")
    irg_add(g, "store i64 " + count2 + ", ptr " + count_p)
    irg_add(g, "ret i1 true")
    irg_add(g, miss_label + ":")
    irg_add(g, "ret i1 false")
    irg_add(g, "}")
}

# ---------------------------------------------------------------------------
# Maybe / Result methods
# ---------------------------------------------------------------------------

public def irg_codegen_maybe_result_method(g: @var IRGen, e: Expr) -> str {
    type_name = irg_expr_type_name(g, e.object.get(0))
    irg_ensure_enum_layout(g, type_name)
    irg_ensure_type(g, type_name)
    self_ptr = irg_object_ptr(g, e.object.get(0))
    if self_ptr.len() == 0 {
        v = irg_codegen_expr(g, e.object.get(0))
        self_ptr = irg_materialize_ptr(g, e.object.get(0), v, type_name)
    }
    disc_p = irg_new_reg(g)
    irg_add(g, disc_p + " = getelementptr %" + type_name + ", ptr " + self_ptr +
              ", i32 0, i32 0")
    disc = irg_new_reg(g)
    irg_add(g, disc + " = load i8, ptr " + disc_p)

    if e.name == "is_some" or e.name == "is_ok" {
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp eq i8 " + disc + ", 0")
        return r
    }
    if e.name == "is_nothing" or e.name == "is_err" {
        r = irg_new_reg(g)
        irg_add(g, r + " = icmp ne i8 " + disc + ", 0")
        return r
    }
    if e.name != "unwrap" and e.name != "expect" {
        return "0"
    }

    ok_label = irg_new_label(g, "uw.ok")
    panic_label = irg_new_label(g, "uw.panic")
    is_err = irg_new_reg(g)
    irg_add(g, is_err + " = icmp ne i8 " + disc + ", 0")
    irg_add(g, "br i1 " + is_err + ", label %" + panic_label + ", label %" + ok_label)

    irg_add(g, panic_label + ":")
    if e.name == "expect" {
        msg = irg_codegen_expr(g, e.args.get(0))
        pm = irg_new_reg(g)
        irg_add(g, pm + " = call i32 (ptr, ...) @printf(ptr " + msg + ")")
    } else {
        if type_name.startswith("Maybe$") {
            m = irg_emit_string_const(g, "panic: unwrap() called on `Nothing`\n")
        } else {
            m = irg_emit_string_const(g, "panic: unwrap() called on `Err` value\n")
        }
        pm2 = irg_new_reg(g)
        irg_add(g, pm2 + " = call i32 (ptr, ...) @printf(ptr " + m + ")")
    }
    irg_add(g, "call void @exit(i32 1)")
    irg_add(g, "unreachable")

    irg_add(g, ok_label + ":")
    kinds_all = g.enum_field_kinds.get(type_name).split("|")
    field_kind = "int"
    if kinds_all.len() > 0 {
        ks = kinds_all.get(0).split(",")
        if ks.len() > 0 {
            field_kind = ks.get(0)
        }
    }
    slot_p = irg_new_reg(g)
    irg_add(g, slot_p + " = getelementptr %" + type_name + ", ptr " + self_ptr +
              ", i32 0, i32 1, i32 0")
    if str_eq(field_kind, "str") {
        r = irg_new_reg(g)
        irg_add(g, r + " = load ptr, ptr " + slot_p)
        return r
    }
    raw = irg_new_reg(g)
    irg_add(g, raw + " = load i64, ptr " + slot_p)
    if str_eq(field_kind, "float") {
        r = irg_new_reg(g)
        irg_add(g, r + " = bitcast i64 " + raw + " to double")
        return r
    }
    if str_eq(field_kind, "bool") {
        r = irg_new_reg(g)
        irg_add(g, r + " = trunc i64 " + raw + " to i1")
        return r
    }
    return raw
}

# ---------------------------------------------------------------------------
# Statement code generation
# ---------------------------------------------------------------------------

public def irg_codegen_stmt(g: @var IRGen, st: Stmt) {
    g.cur_line = st.line
    g.cur_col = st.col
    if st.kind == StmtExpr() {
        if st.expr.kind == ExprIf() {
            irg_codegen_if_stmt(g, st.expr)
        } elif st.expr.kind == ExprMatch() {
            irg_codegen_match_stmt(g, st.expr)
        } else {
            irg_codegen_expr(g, st.expr)
        }
    } elif st.kind == StmtReturn() {
        if st.value.kind == ExprNoneLit() {
            if str_eq(g.cur_fn, "main") {
                irg_add(g, "ret i32 0")
            } else {
                irg_add(g, "ret void")
            }
        } else {
            v = irg_codegen_expr(g, st.value)
            k = irg_expr_kind(g, st.value)
            if str_eq(k, "None") {
                if str_eq(g.cur_fn, "main") {
                    irg_add(g, "ret i32 0")
                } else {
                    irg_add(g, "ret void")
                }
            } else {
                ty = ""
                if str_eq(k, "custom") {
                    ty = "%" + irg_expr_type_name(g, st.value)
                    v = irg_copy_class_value(g, st.value, v)
                } else {
                    ty = irg_llvm_type_of_kind(k)
                }
                # return-type promotion int -> float.
                if str_eq(g.fn_ret_llvm, "double") and not str_eq(k, "float") {
                    cv = irg_new_reg(g)
                    irg_add(g, cv + " = sitofp i64 " + v + " to double")
                    v = cv
                }
                if str_eq(g.cur_fn, "main") and str_eq(k, "int") {
                    tv = irg_new_reg(g)
                    irg_add(g, tv + " = trunc i64 " + v + " to i32")
                    irg_add(g, "ret i32 " + tv)
                } else {
                    irg_add(g, "ret " + ty + " " + v)
                }
            }
        }
    } elif st.kind == StmtFor() {
        irg_codegen_for(g, st)
    } elif st.kind == StmtWhile() {
        irg_codegen_while(g, st)
    } elif st.kind == StmtBreak() {
        if g.loop_exit.len() > 0 {
            irg_add(g, "br label %" + g.loop_exit.get(g.loop_exit.len() - 1))
        }
    } elif st.kind == StmtContinue() {
        if g.loop_continue.len() > 0 {
            irg_add(g, "br label %" + g.loop_continue.get(g.loop_continue.len() - 1))
        }
    }
}

public def irg_codegen_for(g: @var IRGen, st: Stmt) {
    # range(n) / range(start, end) / range(start, end, step).
    if st.iterable.kind == ExprCall() and str_eq(st.iterable.name, "range") {
        argc = st.iterable.args.len()
        start_val = "0"
        end_val = "0"
        step_val = "1"
        if argc == 1 {
            end_val = irg_codegen_expr(g, st.iterable.args.get(0))
        } elif argc == 2 {
            start_val = irg_codegen_expr(g, st.iterable.args.get(0))
            end_val = irg_codegen_expr(g, st.iterable.args.get(1))
        } elif argc >= 3 {
            start_val = irg_codegen_expr(g, st.iterable.args.get(0))
            end_val = irg_codegen_expr(g, st.iterable.args.get(1))
            step_val = irg_codegen_expr(g, st.iterable.args.get(2))
        }
        var_a = irg_new_reg(g)
        irg_add(g, var_a + " = alloca i64")
        irg_add(g, "store i64 " + start_val + ", ptr " + var_a)
        g.var_alloca.put(st.var_name, var_a)
        g.var_kind.put(st.var_name, "int")
        g.var_type_name.put(st.var_name, "")
        g.var_is_ptr.put(st.var_name, 0)
        irg_dbg_declare(g, st.var_name, var_a, "int", "", st.line)

        cond_label = irg_new_label(g, "for.cond")
        body_label = irg_new_label(g, "for.body")
        inc_label = irg_new_label(g, "for.inc")
        exit_label = irg_new_label(g, "for.exit")
        irg_add(g, "br label %" + cond_label)
        irg_add(g, cond_label + ":")
        i = irg_new_reg(g)
        irg_add(g, i + " = load i64, ptr " + var_a)
        step_pos = irg_new_reg(g)
        irg_add(g, step_pos + " = icmp sgt i64 " + step_val + ", 0")
        step_neg = irg_new_reg(g)
        irg_add(g, step_neg + " = icmp slt i64 " + step_val + ", 0")
        lt = irg_new_reg(g)
        irg_add(g, lt + " = icmp slt i64 " + i + ", " + end_val)
        gt = irg_new_reg(g)
        irg_add(g, gt + " = icmp sgt i64 " + i + ", " + end_val)
        c1 = irg_new_reg(g)
        irg_add(g, c1 + " = and i1 " + step_pos + ", " + lt)
        c2 = irg_new_reg(g)
        irg_add(g, c2 + " = and i1 " + step_neg + ", " + gt)
        cond = irg_new_reg(g)
        irg_add(g, cond + " = or i1 " + c1 + ", " + c2)
        irg_add(g, "br i1 " + cond + ", label %" + body_label + ", label %" + exit_label)
        irg_add(g, body_label + ":")
        g.loop_continue.push(inc_label)
        g.loop_exit.push(exit_label)
        k = 0
        while k < st.body.len() {
            irg_codegen_stmt(g, st.body.get(k))
            k = k + 1
        }
        g.loop_continue.pop()
        g.loop_exit.pop()
        if not g.lines.get(g.lines.len() - 1).startswith("br ") {
            irg_add(g, "br label %" + inc_label)
        }
        irg_add(g, inc_label + ":")
        i2 = irg_new_reg(g)
        irg_add(g, i2 + " = load i64, ptr " + var_a)
        i3 = irg_new_reg(g)
        irg_add(g, i3 + " = add i64 " + i2 + ", " + step_val)
        irg_add(g, "store i64 " + i3 + ", ptr " + var_a)
        irg_add(g, "br label %" + cond_label)
        irg_add(g, exit_label + ":")
        return
    }

    # List iteration.
    list_name = irg_expr_type_name(g, st.iterable)
    if list_name.startswith("List$") {
        elem = irg_list_elem_name(list_name)
        elem_ty = irg_elem_llvm_type(g, elem)
        irg_ensure_type(g, list_name)
        lp = irg_object_ptr(g, st.iterable)
        if lp.len() == 0 {
            v = irg_codegen_expr(g, st.iterable)
            lp = irg_materialize_ptr(g, st.iterable, v, list_name)
        }
        data_p = irg_new_reg(g)
        irg_add(g, data_p + " = getelementptr %" + list_name + ", ptr " + lp + ", i32 0, i32 0")
        len_p = irg_new_reg(g)
        irg_add(g, len_p + " = getelementptr %" + list_name + ", ptr " + lp + ", i32 0, i32 1")
        data = irg_new_reg(g)
        irg_add(g, data + " = load ptr, ptr " + data_p)
        n = irg_new_reg(g)
        irg_add(g, n + " = load i64, ptr " + len_p)

        i_a = irg_new_reg(g)
        irg_add(g, i_a + " = alloca i64")
        irg_add(g, "store i64 0, ptr " + i_a)
        x_a = irg_new_reg(g)
        irg_add(g, x_a + " = alloca " + elem_ty)
        g.var_alloca.put(st.var_name, x_a)
        g.var_kind.put(st.var_name, irg_elem_kind(elem))
        if str_eq(irg_elem_kind(elem), "custom") {
            g.var_type_name.put(st.var_name, elem)
        } else {
            g.var_type_name.put(st.var_name, "")
        }
        irg_dbg_declare(g, st.var_name, x_a, irg_elem_kind(elem), g.var_type_name.get(st.var_name), st.line)
        g.var_is_ptr.put(st.var_name, 0)

        cond_label = irg_new_label(g, "for.cond")
        body_label = irg_new_label(g, "for.body")
        inc_label = irg_new_label(g, "for.inc")
        exit_label = irg_new_label(g, "for.exit")
        irg_add(g, "br label %" + cond_label)
        irg_add(g, cond_label + ":")
        i = irg_new_reg(g)
        irg_add(g, i + " = load i64, ptr " + i_a)
        cond = irg_new_reg(g)
        irg_add(g, cond + " = icmp slt i64 " + i + ", " + n)
        irg_add(g, "br i1 " + cond + ", label %" + body_label + ", label %" + exit_label)
        irg_add(g, body_label + ":")
        ep = irg_new_reg(g)
        irg_add(g, ep + " = getelementptr " + elem_ty + ", ptr " + data + ", i64 " + i)
        ev = irg_new_reg(g)
        irg_add(g, ev + " = load " + elem_ty + ", ptr " + ep)
        irg_add(g, "store " + elem_ty + " " + ev + ", ptr " + x_a)
        g.loop_continue.push(inc_label)
        g.loop_exit.push(exit_label)
        k = 0
        while k < st.body.len() {
            irg_codegen_stmt(g, st.body.get(k))
            k = k + 1
        }
        g.loop_continue.pop()
        g.loop_exit.pop()
        if not g.lines.get(g.lines.len() - 1).startswith("br ") {
            irg_add(g, "br label %" + inc_label)
        }
        irg_add(g, inc_label + ":")
        i2 = irg_new_reg(g)
        irg_add(g, i2 + " = load i64, ptr " + i_a)
        i3 = irg_new_reg(g)
        irg_add(g, i3 + " = add i64 " + i2 + ", 1")
        irg_add(g, "store i64 " + i3 + ", ptr " + i_a)
        irg_add(g, "br label %" + cond_label)
        irg_add(g, exit_label + ":")
        return
    }
}

public def irg_codegen_while(g: @var IRGen, st: Stmt) {
    cond_label = irg_new_label(g, "while.cond")
    body_label = irg_new_label(g, "while.body")
    exit_label = irg_new_label(g, "while.exit")
    irg_add(g, "br label %" + cond_label)
    irg_add(g, cond_label + ":")
    cond = irg_codegen_expr(g, st.value)
    irg_add(g, "br i1 " + cond + ", label %" + body_label + ", label %" + exit_label)
    irg_add(g, body_label + ":")
    g.loop_continue.push(cond_label)
    g.loop_exit.push(exit_label)
    k = 0
    while k < st.body.len() {
        irg_codegen_stmt(g, st.body.get(k))
        k = k + 1
    }
    g.loop_continue.pop()
    g.loop_exit.pop()
    if not g.lines.get(g.lines.len() - 1).startswith("br ") {
        irg_add(g, "br label %" + cond_label)
    }
    irg_add(g, exit_label + ":")
}

# ---------------------------------------------------------------------------
# Function code generation
# ---------------------------------------------------------------------------

public def irg_codegen_fn(g: @var IRGen, fn_name: str, f: Stmt, class_name: str) {
    # Reset function-level state.
    g.reg = 0
    g.label = 0
    g.var_alloca = Map[str, str]()
    g.var_kind = Map[str, str]()
    g.var_type_name = Map[str, str]()
    g.var_is_ptr = Map[str, int]()
    g.loop_continue = List[str]()
    g.loop_exit = List[str]()
    g.cur_fn = fn_name
    g.cur_module = f.module_name
    g.fn_ret_kind = type_kind_of_te(f.ret_type)
    g.fn_ret_custom = ""
    if str_eq(g.fn_ret_kind, "custom") {
        g.fn_ret_custom = irg_te_mangled(g, f.ret_type)
    }
    if str_eq(g.fn_ret_kind, "None") {
        g.fn_ret_llvm = "void"
    } else {
        g.fn_ret_llvm = llvm_type_of(g.fn_ret_kind, g.fn_ret_custom)
    }

    is_main = str_eq(fn_name, "main")
    ret_ty = g.fn_ret_llvm
    if is_main {
        ret_ty = "i32"
    }

    # Debug info: the function entry's source location + DISubprogram.
    g.cur_line = f.line
    g.cur_col = f.col
    fn_dbg = ""
    if g.debug_info == 1 and not str_eq(g.di_cu_md, "") {
        g.cur_sp_md = irg_md_subprogram(g, fn_name, @f)
        fn_dbg = " !dbg " + g.cur_sp_md
    } else {
        g.cur_sp_md = ""
    }

    params = g.fn_params_llvm.get(fn_name)
    sig_params = ""
    if is_main {
        sig_params = "i32 %argc, ptr %argv"
    } else {
        pi = 0
        while pi < f.params.len() {
            p = f.params.get(pi)
            pty = ""
            if not str_eq(class_name, "") and str_eq(p.name, "self") {
                pty = "ptr"
            } elif p.type.is_borrow {
                pty = "ptr"
            } else {
                kind = type_kind_of_te(p.type)
                if str_eq(kind, "custom") {
                    pty = "%" + irg_te_mangled(g, p.type)
                } else {
                    pty = llvm_type_of_kind(kind)
                }
            }
            if pi > 0 {
                sig_params = sig_params + ", "
            }
            sig_params = sig_params + pty + " %" + param_name_to_llvm(p.name)
            pi = pi + 1
        }
    }
    irg_add(g, "define " + ret_ty + " @" + fn_name + "(" + sig_params + ")" + fn_dbg + " {")
    entry_label = irg_new_label(g, "entry")
    irg_add(g, entry_label + ":")
    g.in_fn = 1
    g.alloca_lines = List[str]()
    g.fn_entry_idx = g.lines.len()

    if is_main {
        irg_add(g, "store i32 %argc, ptr @rgc.argc")
        irg_add(g, "store ptr %argv, ptr @rgc.argv")
    }

    # Parameter allocas.
    plist = List[Param]()
    i = 0
    while i < f.params.len() {
        p = f.params.get(i)
        arg_reg = "%" + param_name_to_llvm(p.name)
        if i == 0 and is_main {
            # argc/argv already handled.
            i = i + 1
            continue
        }
        if not str_eq(class_name, "") and str_eq(p.name, "self") {
            a = irg_new_reg(g)
            irg_add(g, a + " = alloca ptr")
            irg_add(g, "store ptr " + arg_reg + ", ptr " + a)
            g.var_alloca.put(p.name, a)
            g.var_kind.put(p.name, "custom")
            g.var_type_name.put(p.name, class_name)
            g.var_is_ptr.put(p.name, 1)
            irg_dbg_declare(g, p.name, a, "custom", class_name, f.line)
        } elif p.type.is_borrow {
            # borrow parameters: @T / @var T — the alloca stores a pointer to T.
            a = irg_new_reg(g)
            irg_add(g, a + " = alloca ptr")
            irg_add(g, "store ptr " + arg_reg + ", ptr " + a)
            g.var_alloca.put(p.name, a)
            g.var_kind.put(p.name, "custom")
            g.var_type_name.put(p.name, irg_te_mangled(g, p.type))
            g.var_is_ptr.put(p.name, 1)
            irg_dbg_declare(g, p.name, a, "custom", irg_te_mangled(g, p.type), f.line)
        } else {
            kind = type_kind_of_te(p.type)
            custom = ""
            if str_eq(kind, "custom") {
                custom = irg_te_mangled(g, p.type)
            }
            ty = ""
            if str_eq(kind, "custom") {
                ty = "%" + custom
            } else {
                ty = llvm_type_of_kind(kind)
            }
            a = irg_new_reg(g)
            irg_add(g, a + " = alloca " + ty)
            irg_add(g, "store " + ty + " " + arg_reg + ", ptr " + a)
            g.var_alloca.put(p.name, a)
            g.var_kind.put(p.name, kind)
            g.var_type_name.put(p.name, custom)
            g.var_is_ptr.put(p.name, 0)
            irg_dbg_declare(g, p.name, a, kind, custom, f.line)
        }
        i = i + 1
    }

    # Generate the function body.
    # When there is a trailing expression (no explicit return and a non-void return type), it becomes the return value.
    has_return = False
    k = 0
    while k < f.body.len() {
        st = f.body.get(k)
        if st.kind == StmtReturn() {
            has_return = True
        }
        k = k + 1
    }

    last_is_expr = False
    if f.body.len() > 0 {
        last = f.body.get(f.body.len() - 1)
        if last.kind == StmtExpr() and not is_main and not has_return and
           not str_eq(g.fn_ret_kind, "None") {
            last_is_expr = True
        }
    }

    if last_is_expr {
        k = 0
        while k + 1 < f.body.len() {
            irg_codegen_stmt(g, f.body.get(k))
            k = k + 1
        }
        last_expr = f.body.get(f.body.len() - 1).expr
        ek = irg_expr_kind_ref(g, @last_expr)
        ty = ""
        if str_eq(ek, "custom") {
            ty = "%" + irg_expr_type_name_ref(g, @last_expr)
        } else {
            ty = irg_llvm_type_of_kind(ek)
        }
        v = irg_codegen_expr(g, last_expr)
        if not irg_is_terminated(g) {
            if str_eq(g.fn_ret_llvm, "double") and not str_eq(ek, "float") {
                cv = irg_new_reg(g)
                irg_add(g, cv + " = sitofp i64 " + v + " to double")
                v = cv
            }
            irg_add(g, "ret " + ty + " " + v)
        }
    } else {
        k = 0
        while k < f.body.len() {
            irg_codegen_stmt(g, f.body.get(k))
            k = k + 1
        }
    }

    # Complete the missing terminator.
    last_line = ""
    if g.lines.len() > 0 {
        last_line = g.lines.get(g.lines.len() - 1)
    }
    if not last_line.startswith("ret ") and not last_line.startswith("br ") and
       not str_eq(last_line, "unreachable") {
        if is_main {
            irg_add(g, "ret i32 0")
        } elif str_eq(g.fn_ret_llvm, "void") {
            irg_add(g, "ret void")
        } else {
            zero = ""
            if str_eq(g.fn_ret_llvm, "double") {
                zero = "0.0"
            } elif str_eq(g.fn_ret_llvm, "i1") {
                zero = "false"
            } elif str_eq(g.fn_ret_llvm, "ptr") {
                zero = "null"
            } elif g.fn_ret_llvm.startswith("%") {
                zero = "zeroinitializer"
            } else {
                zero = "0"
            }
            irg_add(g, "ret " + g.fn_ret_llvm + " " + zero)
        }
    }
    irg_add(g, "}")
    g.in_fn = 0
    irg_insert_lines(g, g.fn_entry_idx, g.alloca_lines)
}

# Parameter name -> LLVM parameter register name (RGC parameter names are used directly as IR parameter names).
public def param_name_to_llvm(name: str) -> str {
    return name
}

# ---------------------------------------------------------------------------
# Top-level driver
# ---------------------------------------------------------------------------

public def irg_emit_externs(g: @var IRGen) {
    irg_extern(g, "i32 @printf(ptr, ...)")
    irg_extern(g, "i32 @snprintf(ptr, i64, ptr, ...)")
    irg_extern(g, "i64 @strlen(ptr)")
    irg_extern(g, "i32 @strcmp(ptr, ptr)")
    irg_extern(g, "i32 @strncmp(ptr, ptr, i64)")
    irg_extern(g, "ptr @strstr(ptr, ptr)")
    irg_extern(g, "i64 @strtoll(ptr, ptr, i32)")
    irg_extern(g, "double @strtod(ptr, ptr)")
    irg_extern(g, "double @atof(ptr)")
    irg_extern(g, "ptr @malloc(i64)")
    irg_extern(g, "void @free(ptr)")
    irg_extern(g, "ptr @realloc(ptr, i64)")
    irg_extern(g, "i32 @pthread_create(ptr, ptr, ptr, ptr)")
    irg_extern(g, "i32 @pthread_join(i64, ptr)")
    irg_extern(g, "ptr @memcpy(ptr, ptr, i64)")
    irg_extern(g, "ptr @memmove(ptr, ptr, i64)")
    irg_extern(g, "void @memset(ptr, i32, i64)")
    irg_extern(g, "i32 @system(ptr)")
    irg_extern(g, "i32 @remove(ptr)")
    irg_extern(g, "i32 @access(ptr, i32)")
    irg_extern(g, "i64 @write(i32, ptr, i64)")
    irg_extern(g, "i32 @rgc_emit_object(ptr, ptr)")
    irg_extern(g, "ptr @fopen(ptr, ptr)")
    irg_extern(g, "i64 @fread(ptr, i64, i64, ptr)")
    irg_extern(g, "i64 @fwrite(ptr, i64, i64, ptr)")
    irg_extern(g, "i32 @fclose(ptr)")
    irg_extern(g, "i32 @fseek(ptr, i64, i32)")
    irg_extern(g, "i64 @ftell(ptr)")
    irg_extern(g, "void @exit(i32)")
    irg_extern(g, "i32 @clock_gettime(i32, ptr)")
    irg_extern(g, "i64 @time(ptr)")
    irg_extern(g, "i32 @nanosleep(ptr, ptr)")
    irg_extern(g, "ptr @getenv(ptr)")
    irg_extern(g, "i32 @setenv(ptr, ptr, i32)")
    irg_extern(g, "ptr @getcwd(ptr, i64)")
    # Parameters are uniformly i64: extern def's int maps to i64, ABI-compatible with C int parameters on x86_64 System V.
    irg_extern(g, "i32 @socket(i64, i64, i64)")
    irg_extern(g, "i32 @connect(i64, ptr, i64)")
    irg_extern(g, "i32 @bind(i64, ptr, i64)")
    irg_extern(g, "i32 @listen(i64, i64)")
    irg_extern(g, "i32 @accept(i64, ptr, ptr)")
    irg_extern(g, "i32 @setsockopt(i64, i64, i64, ptr, i64)")
    irg_extern(g, "i32 @getsockname(i64, ptr, ptr)")
    irg_extern(g, "i32 @close(i64)")
    irg_extern(g, "i32 @send(i64, ptr, i64, i64)")
    irg_extern(g, "i32 @recv(i64, ptr, i64, i64)")
    irg_extern(g, "ptr @gethostbyname(ptr)")
    irg_extern(g, "ptr @__errno_location()")
    irg_extern(g, "ptr @strerror(i64)")
    irg_extern(g, "double @llvm.pow.f64(double, double)")
    irg_extern(g, "double @llvm.fabs.f64(double)")
    irg_extern(g, "double @llvm.sqrt.f64(double)")
    irg_extern(g, "double @llvm.floor.f64(double)")
    irg_extern(g, "double @llvm.ceil.f64(double)")
}

# Generate the full module IR text.
# Emit C ABI declares for extern defs (type mapping is in sema_register_fn).
public def irg_emit_extern_fn_decl(g: @var IRGen, fn: str) {
    # Deduplicate by function name: the same extern may come from multiple modules/builtin tables with different text formats.
    name_key = "fn@" + fn
    if g.emitted_externs.contains(name_key) {
        return
    }
    g.emitted_externs.put(name_key, 1)
    ret = g.fn_ret_llvm_map.get(fn)
    params = g.fn_params_llvm.get(fn)
    irg_extern(g, ret + " @" + fn + "(" + params + ")")
}

public def irg_generate(g: @var IRGen, stmts: List[Stmt]) -> str {
    # Module header.
    src_name = "rgc.ll"
    if g.source_path.len() > 0 {
        src_name = g.source_path
    }
    irg_add(g, "; module generated by rgc ")
    irg_add(g, "source_filename = " + irg_md_quote(src_name))
    irg_add(g, "target triple = \"x86_64-unknown-linux-gnu\"")

    # Backend options: passed to the embedded LLVM shim via named metadata (keeping the emit_object builtin signature unchanged).
    opt_md = irg_md_alloc(g)
    g.md_defs.push(opt_md + " = !{i32 " + to_string(g.opt_level) +
                   ", i32 " + to_string(g.debug_info) + "}")
    irg_add(g, "!rgc.options = !{" + opt_md + "}")

    # Module-level debug metadata (DIFile / DICompileUnit / module flags).
    if g.debug_info == 1 {
        dir_part = "."
        file_part = src_name
        idx = str_rfind(src_name, "/")
        if idx >= 0 {
            dir_part = src_name.slice(0, idx)
            file_part = src_name.slice(idx + 1, src_name.len())
        }
        g.di_file_md = irg_md_alloc(g)
        g.di_cu_md = irg_md_alloc(g)
        flags_md = irg_md_alloc(g)
        g.md_defs.push(g.di_file_md + " = !DIFile(filename: " + irg_md_quote(file_part) +
                       ", directory: " + irg_md_quote(dir_part) + ")")
        iso = "false"
        if g.opt_level > 0 {
            iso = "true"
        }
        g.md_defs.push(g.di_cu_md +
                       " = distinct !DICompileUnit(language: DW_LANG_C99, file: " +
                       g.di_file_md + ", producer: \"rgc\", isOptimized: " + iso +
                       ", runtimeVersion: 0, emissionKind: FullDebug, enums: !{})")
        g.md_defs.push(flags_md + " = !{i32 7, !\"Debug Info Version\", i32 3}")
        irg_add(g, "!llvm.module.flags = !{" + flags_md + "}")
        irg_add(g, "!llvm.dbg.cu = !{" + g.di_cu_md + "}")
    }
    irg_add(g, "@rgc.argc = internal global i32 0")
    irg_add(g, "@rgc.argv = internal global ptr null")
    irg_add(g, "@rgc.rand_state = internal global i64 88172645463325252")
    irg_add(g, "@rgc.tls_cancel = internal thread_local global ptr null")
    if g.debug_info == 1 {
        irg_extern(g, "void @llvm.dbg.declare(metadata, metadata, metadata)")
    }
    irg_emit_externs(g)

    # Predeclare all types.
    i = 0
    while i < g.class_order.len() {
        irg_ensure_type(g, g.class_order.get(i))
        i = i + 1
    }
    i = 0
    while i < g.enum_order.len() {
        irg_ensure_type(g, g.enum_order.get(i))
        i = i + 1
    }
    i = 0
    while i < g.fn_order.len() {
        fn = g.fn_order.get(i)
        ret = g.fn_ret_llvm_map.get(fn)
        if ret.startswith("%") {
            irg_ensure_type(g, ret.slice(1, ret.len()))
        }
        params = g.fn_params_llvm.get(fn)
        if params.len() > 0 {
            plist = params.split(",")
            j = 0
            while j < plist.len() {
                p = plist.get(j)
                if p.startswith("%") {
                    irg_ensure_type(g, p.slice(1, p.len()))
                }
                j = j + 1
            }
        }
        i = i + 1
    }

    # Subsequent irg_add calls belong to the function body.
    g.body_start = g.lines.len()

    # Emit functions; generic templates are skipped, concrete instances come from extra_stmts; extern defs only get declares.
    i = 0
    while i < stmts.len() {
        st = stmts.get(i)
        if st.type_params.len() == 0 {
            if st.kind == StmtFnDef() {
                sym = irg_fn_sym(@st)
                if st.is_extern {
                    irg_emit_extern_fn_decl(g, sym)
                } else {
                    irg_codegen_fn(g, sym, st, "")
                }
            } elif st.kind == StmtClassDef() {
                j = 0
                while j < st.methods.len() {
                    m = st.methods.get(j)
                    m.module_name = st.module_name
                    irg_codegen_fn(g, st.name + "$" + m.name, m, st.name)
                    j = j + 1
                }
            }
        }
        i = i + 1
    }
    i = 0
    while i < g.extra_stmts.len() {
        st = g.extra_stmts.get(i)
        if st.kind == StmtFnDef() {
            sym2 = irg_fn_sym(@st)
            irg_codegen_fn(g, sym2, st, "")
        } elif st.kind == StmtClassDef() {
            j = 0
            while j < st.methods.len() {
                m = st.methods.get(j)
                m.module_name = st.module_name
                irg_codegen_fn(g, st.name + "$" + m.name, m, st.name)
                j = j + 1
            }
        }
        i = i + 1
    }

    # Map hash/find/put/remove helpers are registered on demand while emitting bodies.
    irg_emit_map_helpers(g)

    # Thread wrapper functions must be emitted after all async functions.
    i = 0
    while i < g.async_wrappers.len() {
        irg_emit_async_wrapper(g, g.async_wrappers.get(i))
        i = i + 1
    }
    i = 0
    while i < g.gather_wrappers.len() {
        irg_emit_gather_wrapper(g, g.gather_wrappers.get(i))
        i = i + 1
    }

    # Join the output (linear join allocation, avoiding O(n^2) string accumulation).
    all = List[str]()
    i = 0
    while i < g.body_start {
        all.push(g.lines.get(i))
        i = i + 1
    }
    i = 0
    while i < g.type_lines.len() {
        all.push(g.type_lines.get(i))
        i = i + 1
    }
    i = g.body_start
    while i < g.lines.len() {
        all.push(g.lines.get(i))
        i = i + 1
    }
    i = 0
    while i < g.string_lines.len() {
        all.push(g.string_lines.get(i))
        i = i + 1
    }
    i = 0
    while i < g.md_defs.len() {
        all.push(g.md_defs.get(i))
        i = i + 1
    }
    return "\n".join(all) + "\n"
}