# RGC standard library: json
#
# Usage:
#   import json
#   r = json.parse(text)
#   if r.ok { v = r.value; print(json.stringify(@v)) } else { print(r.error) }
#
# JsonValue recurses through List (the language does not allow a class to contain itself by value).
# Parse results are carried by the JsonParse class with ok/error/value, avoiding custom Result payload limits.

public class JsonValue {
    kind: int          # 0 null, 1 bool, 2 int, 3 float, 4 str, 5 array, 6 object
    b: bool
    i: int
    f: float
    s: str             # string value / raw number text
    arr: List[JsonValue]
    keys: List[str]
    vals: List[JsonValue]
}

public class JsonParse {
    ok: bool
    error: str
    value: JsonValue
}

class JsonParser {
    text: str
    pos: int
    err: str
    depth: int

    def ws(self) {
        while self.pos < self.text.len() {
            c = self.text.char_at(self.pos)
            if c != 32 and c != 9 and c != 10 and c != 13 {
                break
            }
            self.pos = self.pos + 1
        }
    }

    def fail(self, msg: str) {
        if self.err.len() == 0 {
            self.err = msg
        }
    }

    def expect_word(self, word: str) -> bool {
        if self.pos + word.len() > self.text.len() {
            self.fail("unexpected end of input")
            return False
        }
        got = self.text.slice(self.pos, self.pos + word.len())
        if got != word {
            self.fail("invalid literal")
            return False
        }
        self.pos = self.pos + word.len()
        return True
    }

    def hex_digit(self) -> int {
        if self.pos >= self.text.len() {
            return -1
        }
        c = self.text.char_at(self.pos)
        if c >= 48 and c <= 57 {
            return c - 48
        }
        if c >= 97 and c <= 102 {
            return c - 87
        }
        if c >= 65 and c <= 70 {
            return c - 55
        }
        return -1
    }

    # Read 4 hex digits from the current pos and advance; returns -1 on failure.
    def hex4(self) -> int {
        v = 0
        i = 0
        while i < 4 {
            d = self.hex_digit()
            if d < 0 {
                self.fail("invalid unicode escape")
                return -1
            }
            v = v * 16 + d
            self.pos = self.pos + 1
            i = i + 1
        }
        return v
    }

    # `\u` already consumed; parse the code point plus an optional surrogate pair, then append UTF-8.
    def unicode_escape(self, out: str) -> str {
        cp = self.hex4()
        if cp < 0 {
            return out
        }
        if cp >= 55296 and cp <= 56319 {   # high surrogate
            if self.pos + 1 >= self.text.len() or
               self.text.char_at(self.pos) != 92 or self.text.char_at(self.pos + 1) != 117 {
                self.fail("invalid unicode escape")
                return out
            }
            self.pos = self.pos + 2
            low = self.hex4()
            if low < 0 {
                return out
            }
            if low < 56320 or low > 57343 {
                self.fail("invalid unicode escape")
                return out
            }
            cp = 65536 + ((cp - 55296) << 10) + (low - 56320)
        } elif cp >= 56320 and cp <= 57343 {
            self.fail("invalid unicode escape")
            return out
        }
        if cp == 0 {
            self.fail("NUL character not supported")
            return out
        }
        return out + chr(cp)
    }

    def string_value(self) -> JsonValue {
        self.pos = self.pos + 1   # "
        out = ""
        while self.pos < self.text.len() {
            c = self.text.char_at(self.pos)
            if c == 34 {
                self.pos = self.pos + 1
                return json_str(out)
            }
            if c == 92 {
                self.pos = self.pos + 1
                if self.pos >= self.text.len() {
                    self.fail("unterminated escape")
                    return json_str(out)
                }
                e = self.text.char_at(self.pos)
                self.pos = self.pos + 1
                if e == 34 {
                    out = out + "\""
                } elif e == 92 {
                    out = out + "\\"
                } elif e == 47 {
                    out = out + "/"
                } elif e == 98 {
                    out = out + chr(8)
                } elif e == 102 {
                    out = out + chr(12)
                } elif e == 110 {
                    out = out + "\n"
                } elif e == 114 {
                    out = out + "\r"
                } elif e == 116 {
                    out = out + "\t"
                } elif e == 117 {
                    out = self.unicode_escape(out)
                    if self.err.len() > 0 {
                        return json_str(out)
                    }
                } else {
                    self.fail("unsupported escape")
                    return json_str(out)
                }
                pass
            } else {
                if c < 32 {
                    self.fail("unescaped control character")
                    return json_str(out)
                }
                out = out + self.text.slice(self.pos, self.pos + 1)
                self.pos = self.pos + 1
                pass
            }
        }
        self.fail("unterminated string")
        return json_str(out)
    }

    def number_value(self) -> JsonValue {
        start = self.pos
        if self.pos < self.text.len() and self.text.char_at(self.pos) == 45 {
            self.pos = self.pos + 1
        }
        int_digits = 0
        while self.pos < self.text.len() {
            c = self.text.char_at(self.pos)
            if c < 48 or c > 57 {
                break
            }
            self.pos = self.pos + 1
            int_digits = int_digits + 1
        }
        if int_digits == 0 {
            self.fail("invalid number")
            return json_null()
        }
        first = self.text.char_at(start)
        if first == 45 {
            first = self.text.char_at(start + 1)
        }
        if first == 48 and int_digits > 1 {
            self.fail("invalid number")
            return json_null()
        }
        is_float = False
        if self.pos < self.text.len() and self.text.char_at(self.pos) == 46 {
            is_float = True
            self.pos = self.pos + 1
            frac_digits = 0
            while self.pos < self.text.len() {
                c = self.text.char_at(self.pos)
                if c < 48 or c > 57 {
                    break
                }
                self.pos = self.pos + 1
                frac_digits = frac_digits + 1
            }
            if frac_digits == 0 {
                self.fail("invalid number")
                return json_null()
            }
        }
        if self.pos < self.text.len() and
           (self.text.char_at(self.pos) == 101 or self.text.char_at(self.pos) == 69) {
            is_float = True
            self.pos = self.pos + 1
            if self.pos < self.text.len() and
               (self.text.char_at(self.pos) == 43 or self.text.char_at(self.pos) == 45) {
                self.pos = self.pos + 1
            }
            exp_digits = 0
            while self.pos < self.text.len() {
                c = self.text.char_at(self.pos)
                if c < 48 or c > 57 {
                    break
                }
                self.pos = self.pos + 1
                exp_digits = exp_digits + 1
            }
            if exp_digits == 0 {
                self.fail("invalid number")
                return json_null()
            }
        }
        raw = self.text.slice(start, self.pos)
        if is_float {
            return json_float_from(raw)
        }
        if not int_in_range(raw) {
            self.fail("integer out of range")
            return json_null()
        }
        return json_int_from(raw)
    }

    def array_value(self) -> JsonValue {
        self.depth = self.depth + 1
        if self.depth > 256 {
            self.fail("nesting too deep")
            return json_array()
        }
        self.pos = self.pos + 1   # [
        v = json_array()
        self.ws()
        if self.pos < self.text.len() and self.text.char_at(self.pos) == 93 {
            self.pos = self.pos + 1
            self.depth = self.depth - 1
            return v
        }
        while True {
            item = self.value()
            if self.err.len() > 0 {
                return v
            }
            v.arr.push(item)
            self.ws()
            if self.pos >= self.text.len() {
                self.fail("unterminated array")
                return v
            }
            c = self.text.char_at(self.pos)
            if c == 44 {
                self.pos = self.pos + 1
                continue
            }
            if c == 93 {
                self.pos = self.pos + 1
                self.depth = self.depth - 1
                return v
            }
            self.fail("expected `,` or `]`")
            return v
        }
        return v
    }

    def object_value(self) -> JsonValue {
        self.depth = self.depth + 1
        if self.depth > 256 {
            self.fail("nesting too deep")
            return json_object()
        }
        self.pos = self.pos + 1   # {
        v = json_object()
        self.ws()
        if self.pos < self.text.len() and self.text.char_at(self.pos) == 125 {
            self.pos = self.pos + 1
            self.depth = self.depth - 1
            return v
        }
        while True {
            self.ws()
            if self.pos >= self.text.len() or self.text.char_at(self.pos) != 34 {
                self.fail("expected object key")
                return v
            }
            key = self.string_value()
            if self.err.len() > 0 {
                return v
            }
            self.ws()
            if self.pos >= self.text.len() or self.text.char_at(self.pos) != 58 {
                self.fail("expected `:`")
                return v
            }
            self.pos = self.pos + 1
            item = self.value()
            if self.err.len() > 0 {
                return v
            }
            v.keys.push(key.s)
            v.vals.push(item)
            self.ws()
            if self.pos >= self.text.len() {
                self.fail("unterminated object")
                return v
            }
            c = self.text.char_at(self.pos)
            if c == 44 {
                self.pos = self.pos + 1
                continue
            }
            if c == 125 {
                self.pos = self.pos + 1
                self.depth = self.depth - 1
                return v
            }
            self.fail("expected `,` or `}`")
            return v
        }
        return v
    }

    def value(self) -> JsonValue {
        self.ws()
        if self.pos >= self.text.len() {
            self.fail("unexpected end of input")
            return json_null()
        }
        c = self.text.char_at(self.pos)
        if c == 34 {
            return self.string_value()
        }
        if c == 91 {
            return self.array_value()
        }
        if c == 123 {
            return self.object_value()
        }
        if c == 116 {
            if self.expect_word("true") {
                return json_bool(True)
            }
            return json_null()
        }
        if c == 102 {
            if self.expect_word("false") {
                return json_bool(False)
            }
            return json_null()
        }
        if c == 110 {
            if self.expect_word("null") {
                return json_null()
            }
            return json_null()
        }
        if c == 45 or (c >= 48 and c <= 57) {
            return self.number_value()
        }
        self.fail("unexpected character")
        return json_null()
    }
}

def json_null() -> JsonValue {
    v = JsonValue()
    v.kind = 0
    v.b = False
    v.i = 0
    v.f = 0.0
    v.s = ""
    v.arr = List[JsonValue]()
    v.keys = List[str]()
    v.vals = List[JsonValue]()
    return v
}

def json_bool(b: bool) -> JsonValue {
    v = json_null()
    v.kind = 1
    v.b = b
    return v
}

# Whether the decimal integer fits in i64 (to_int truncates silently on overflow via strtoll).
def int_in_range(raw: str) -> bool {
    digits = raw
    if digits.len() > 0 and digits.char_at(0) == 45 {
        digits = digits.slice(1, digits.len())
    }
    if digits.len() > 19 {
        return False
    }
    if digits.len() < 19 {
        return True
    }
    limit = "9223372036854775807"
    if raw.len() > 0 and raw.char_at(0) == 45 {
        limit = "9223372036854775808"
    }
    i = 0
    while i < 19 {
        a = digits.char_at(i)
        b = limit.char_at(i)
        if a < b {
            return True
        }
        if a > b {
            return False
        }
        i = i + 1
    }
    return True
}

def json_int_from(raw: str) -> JsonValue {
    v = json_null()
    v.kind = 2
    r = raw.to_int()
    if r.is_ok() {
        v.i = r.unwrap()
    }
    v.s = raw
    return v
}

def json_float_from(raw: str) -> JsonValue {
    v = json_null()
    v.kind = 3
    r = raw.to_float()
    if r.is_ok() {
        v.f = r.unwrap()
    }
    v.s = raw
    return v
}

def json_str(s: str) -> JsonValue {
    v = json_null()
    v.kind = 4
    v.s = s
    return v
}

def json_array() -> JsonValue {
    v = json_null()
    v.kind = 5
    return v
}

def json_object() -> JsonValue {
    v = json_null()
    v.kind = 6
    return v
}

# ---------- public construction API ----------

public def null() -> JsonValue {
    return json_null()
}

public def bool_value(b: bool) -> JsonValue {
    return json_bool(b)
}

public def int_value(n: int) -> JsonValue {
    v = json_null()
    v.kind = 2
    v.i = n
    v.s = to_string(n)
    return v
}

public def float_value(x: float) -> JsonValue {
    v = json_null()
    v.kind = 3
    v.f = x
    v.s = to_string(x)
    return v
}

public def str_value(s: str) -> JsonValue {
    return json_str(s)
}

public def array() -> JsonValue {
    return json_array()
}

public def object() -> JsonValue {
    return json_object()
}

# ---------- public access API ----------

public def kind(v: @JsonValue) -> int {
    return v.kind
}

public def is_null(v: @JsonValue) -> bool {
    return v.kind == 0
}

public def as_bool(v: @JsonValue) -> bool {
    return v.b
}

public def as_int(v: @JsonValue) -> int {
    return v.i
}

public def as_float(v: @JsonValue) -> float {
    if v.kind == 2 {
        return v.i + 0.0
    }
    return v.f
}

public def as_str(v: @JsonValue) -> str {
    return v.s
}

public def len(v: @JsonValue) -> int {
    if v.kind == 5 {
        return v.arr.len()
    }
    if v.kind == 6 {
        return v.keys.len()
    }
    return 0
}

public def at(v: @JsonValue, i: int) -> JsonValue {
    if v.kind == 5 and i >= 0 and i < v.arr.len() {
        return v.arr.get(i)
    }
    return json_null()
}

public def key_at(v: @JsonValue, i: int) -> str {
    if v.kind == 6 and i >= 0 and i < v.keys.len() {
        return v.keys.get(i)
    }
    return ""
}

public def val_at(v: @JsonValue, i: int) -> JsonValue {
    if v.kind == 6 and i >= 0 and i < v.vals.len() {
        return v.vals.get(i)
    }
    return json_null()
}

public def has_key(v: @JsonValue, key: str) -> bool {
    if v.kind != 6 {
        return False
    }
    i = 0
    while i < v.keys.len() {
        if v.keys.get(i) == key {
            return True
        }
        i = i + 1
    }
    return False
}

public def get(v: @JsonValue, key: str) -> JsonValue {
    if v.kind == 6 {
        i = 0
        while i < v.keys.len() {
            if v.keys.get(i) == key {
                return v.vals.get(i)
            }
            i = i + 1
        }
    }
    return json_null()
}

public def push(v: @var JsonValue, item: JsonValue) {
    if v.kind == 5 {
        v.arr.push(item)
    }
}

public def set(v: @var JsonValue, key: str, item: JsonValue) {
    if v.kind != 6 {
        return
    }
    i = 0
    while i < v.keys.len() {
        if v.keys.get(i) == key {
            v.vals.set(i, item)
            return
        }
        i = i + 1
    }
    v.keys.push(key)
    v.vals.push(item)
}

public def set_at(v: @var JsonValue, i: int, item: JsonValue) {
    if v.kind == 5 and i >= 0 and i < v.arr.len() {
        v.arr.set(i, item)
    }
}

public def remove_at(v: @var JsonValue, i: int) -> bool {
    if v.kind != 5 or i < 0 or i >= v.arr.len() {
        return False
    }
    j = i
    while j + 1 < v.arr.len() {
        v.arr.set(j, v.arr.get(j + 1))
        j = j + 1
    }
    dropped = v.arr.pop()
    return True
}

public def remove(v: @var JsonValue, key: str) -> bool {
    if v.kind != 6 {
        return False
    }
    i = 0
    while i < v.keys.len() {
        if v.keys.get(i) == key {
            j = i
            while j + 1 < v.keys.len() {
                v.keys.set(j, v.keys.get(j + 1))
                v.vals.set(j, v.vals.get(j + 1))
                j = j + 1
            }
            dropped_key = v.keys.pop()
            dropped_val = v.vals.pop()
            return True
        }
        i = i + 1
    }
    return False
}

# ---------- parsing / serialization ----------

public def parse(text: str) -> JsonParse {
    p = JsonParser()
    p.text = text
    p.pos = 0
    p.err = ""
    p.depth = 0
    v = p.value()
    p.ws()
    if p.err.len() == 0 and p.pos != text.len() {
        p.fail("trailing characters")
    }
    r = JsonParse()
    r.ok = p.err.len() == 0
    r.error = p.err
    r.value = v
    return r
}

def non_finite_text(s: str) -> bool {
    if s == "inf" or s == "-inf" or s == "nan" or s == "-nan" {
        return True
    }
    if s == "Infinity" or s == "-Infinity" or s == "NaN" {
        return True
    }
    return False
}

def escape_json(s: str) -> str {
    hexd = "0123456789abcdef"
    out = "\""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 34 {
            out = out + "\\\""
        } elif c == 92 {
            out = out + "\\\\"
        } elif c == 8 {
            out = out + "\\b"
        } elif c == 9 {
            out = out + "\\t"
        } elif c == 10 {
            out = out + "\\n"
        } elif c == 12 {
            out = out + "\\f"
        } elif c == 13 {
            out = out + "\\r"
        } elif c < 32 {
            hi = c >> 4
            lo = c & 15
            out = out + "\\u00" + hexd.slice(hi, hi + 1) + hexd.slice(lo, lo + 1)
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out + "\""
}

public def stringify(v: @JsonValue) -> str {
    if v.kind == 0 {
        return "null"
    }
    if v.kind == 1 {
        if v.b {
            return "true"
        }
        return "false"
    }
    if v.kind == 2 {
        if v.s.len() > 0 {
            return v.s
        }
        return to_string(v.i)
    }
    if v.kind == 3 {
        if v.s.len() > 0 {
            if non_finite_text(v.s) {
                return "null"
            }
            return v.s
        }
        text = to_string(v.f)
        if non_finite_text(text) {
            return "null"
        }
        return text
    }
    if v.kind == 4 {
        return escape_json(v.s)
    }
    if v.kind == 5 {
        out = "["
        i = 0
        while i < v.arr.len() {
            if i > 0 {
                out = out + ","
            }
            child = v.arr.get(i)
            out = out + stringify(@child)
            i = i + 1
        }
        return out + "]"
    }
    out = "{"
    i = 0
    while i < v.keys.len() {
        if i > 0 {
            out = out + ","
        }
        out = out + escape_json(v.keys.get(i)) + ":"
        child = v.vals.get(i)
        out = out + stringify(@child)
        i = i + 1
    }
    return out + "}"
}
