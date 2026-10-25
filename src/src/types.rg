# RGC compiler: type representation
#
# Primitive types: int/float/bool/str/None; custom types (classes/enums/List$...) use
# name to store a mangled name (e.g. `List$int`, `Maybe$int`, `Point`).
# Type kinds are passed between the symbol table and IR generation as string names ("int"/"float"/...).

public enum TypeKind {
    TypeInt
    TypeFloat
    TypeBool
    TypeString
    TypeNone
    TypeCustom
    TypeError
    TypeBorrow # @T
    TypeMutBorrow # @var T
}

public class Type {
    kind: TypeKind
    name: str
}

# ---------- constructor helpers ----------

public def type_int() -> Type {
    t = Type()
    t.kind = TypeInt()
    return t
}

public def type_float() -> Type {
    t = Type()
    t.kind = TypeFloat()
    return t
}

public def type_bool() -> Type {
    t = Type()
    t.kind = TypeBool()
    return t
}

public def type_string() -> Type {
    t = Type()
    t.kind = TypeString()
    return t
}

public def type_none() -> Type {
    t = Type()
    t.kind = TypeNone()
    return t
}

public def type_custom(name: str) -> Type {
    t = Type()
    t.kind = TypeCustom()
    t.name = name
    return t
}

public def type_error() -> Type {
    t = Type()
    t.kind = TypeError()
    return t
}

# String name of a type (for Map keys / IR type selection).
# Returns "int"/"float"/"bool"/"str"/"None"/"custom".
public def type_kind_name(t: Type) -> str {
    if t.kind == TypeInt() { return "int" }
    elif t.kind == TypeFloat() { return "float" }
    elif t.kind == TypeBool() { return "bool" }
    elif t.kind == TypeString() { return "str" }
    elif t.kind == TypeNone() { return "None" }
    elif t.kind == TypeCustom() { return "custom" }
    return "error"
}

# Display name (used in error messages).
public def type_display(t: Type) -> str {
    if t.kind == TypeInt() {
        return "int"
    } elif t.kind == TypeFloat() {
        return "float"
    } elif t.kind == TypeBool() {
        return "bool"
    } elif t.kind == TypeString() {
        return "str"
    } elif t.kind == TypeNone() {
        return "None"
    } elif t.kind == TypeBorrow() {
        return "@" + type_display_inner(t)
    } elif t.kind == TypeMutBorrow() {
        return "@var " + type_display_inner(t)
    } elif t.kind == TypeCustom() {
        return t.name
    }
    return "<error>"
}

public def type_display_inner(t: Type) -> str {
    return t.name
}
