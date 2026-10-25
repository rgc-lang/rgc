import json

def probe(t: str) {
    r = json.parse(t)
    if r.ok {
        v = r.value
        print("ok  [" + t + "] -> " + json.stringify(@v))
    } else {
        print("err [" + t + "] -> " + r.error)
    }
}

def nested(n: int) -> str {
    s = ""
    i = 0
    while i < n {
        s = s + "["
        i = i + 1
    }
    i = 0
    while i < n {
        s = s + "]"
        i = i + 1
    }
    return s
}

def main() -> int {
    r = json.parse("{\"name\":\"rgc\",\"n\":3,\"pi\":3.5,\"ok\":true,\"none\":null,\"xs\":[1,2,\"three\"],\"nested\":{\"k\":false}}")
    if not r.ok {
        print("parse failed:", r.error)
        return 1
    }
    v = r.value
    print("round", json.stringify(@v))
    print("len", json.len(@v))
    print("name", json.as_str(json.get(@v, "name")))
    print("n", json.as_int(json.get(@v, "n")))
    print("pi", json.as_float(json.get(@v, "pi")))
    print("ok", json.as_bool(json.get(@v, "ok")))
    print("none", json.is_null(json.get(@v, "none")))
    print("has", json.has_key(@v, "xs"), json.has_key(@v, "missing"))
    print("key0", json.key_at(@v, 0))
    print("val0", json.as_str(json.val_at(@v, 0)))

    xs = json.get(@v, "xs")
    print("xslen", json.len(@xs))
    print("x0", json.as_int(json.at(@xs, 0)))
    print("x2", json.as_str(json.at(@xs, 2)))
    nested = json.get(@v, "nested")
    print("nested", json.stringify(@nested))

    obj = json.object()
    json.set(@var obj, "id", json.int_value(7))
    tags = json.array()
    json.push(@var tags, json.str_value("a"))
    json.push(@var tags, json.str_value("b"))
    json.set(@var obj, "tags", tags)
    json.set(@var obj, "pi", json.float_value(1.5))
    json.set(@var obj, "flag", json.bool_value(True))
    json.set(@var obj, "none", json.null())
    print("built", json.stringify(@obj))

    esc = json.parse("{\"s\":\"a\\nb\\t\\\"c\\\\d\\/e\"}")
    ev = esc.value
    print("esc_ok", esc.ok)
    print("esc", json.stringify(@ev))
    print("esc_len", json.as_str(json.get(@ev, "s")).len())

    empty = json.parse("[]")
    av = empty.value
    print("empty", empty.ok, json.len(@av), json.as_int(json.at(@av, 5)))

    mixed = json.parse("[-0.5e2, 17]")
    mv = mixed.value
    print("mixed", json.as_float(json.at(@mv, 0)), json.as_int(json.at(@mv, 1)))

    probe("[1,]")
    probe("1 2")
    probe("\"unterminated")
    probe("{\"a\":1")
    probe("tru")
    probe("-")
    probe("1.")
    probe("1e")
    probe("01")

    u = json.parse("\"\\u0041\\u00e9\\u4f60\\ud83d\\ude00\"")
    uv = u.value
    us = json.as_str(@uv)
    print("uni", u.ok, us, us.len())
    print("uni_out", json.stringify(@uv))

    bf = json.parse("\"a\\bb\\fc\"")
    bv = bf.value
    bs = json.as_str(@bv)
    print("bf", bf.ok, bs.len(), json.stringify(@bv))

    ctrl = json.str_value(chr(1))
    print("ctrl", json.stringify(@ctrl))

    probe("\"\\uD800\"")
    probe("\"\\uDC00\"")
    probe("\"\\uD83D\\u0041\"")
    probe("\"\\u12x4\"")
    probe("\"\\u12\"")
    probe("\"\\u0000\"")
    probe("\"\\q\"")

    raw_nl = json.parse("\"" + chr(10) + "\"")
    print("raw_nl", raw_nl.ok, raw_nl.error)
    raw_tab = json.parse("\"" + chr(9) + "\"")
    print("raw_tab", raw_tab.ok, raw_tab.error)

    big = json.parse("9223372036854775807")
    bigv = big.value
    print("imax", big.ok, json.as_int(@bigv))
    small = json.parse("-9223372036854775808")
    smallv = small.value
    print("imin", small.ok, json.as_int(@smallv))
    probe("9223372036854775808")
    probe("-9223372036854775809")
    probe("12345678901234567890")

    okd = json.parse(nested(256))
    print("depth256", okd.ok)
    badd = json.parse(nested(257))
    print("depth257", badd.ok, badd.error)

    r = json.parse("[1,2,3]")
    a = r.value
    json.set_at(@var a, 1, json.int_value(20))
    print("set_at", json.stringify(@a))
    rm1 = json.remove_at(@var a, 0)
    print("remove_at", rm1, json.stringify(@a))
    rm2 = json.remove_at(@var a, 9)
    print("remove_at_bad", rm2, json.stringify(@a))

    ro = json.parse("{\"a\":1,\"b\":2}")
    ov = ro.value
    rk = json.remove(@var ov, "a")
    print("remove_key", rk, json.stringify(@ov))
    rk2 = json.remove(@var ov, "z")
    print("remove_missing", rk2, json.stringify(@ov))

    inf = json.float_value("inf".to_float().unwrap())
    print("inf", json.stringify(@inf))
    ninf = json.float_value("-inf".to_float().unwrap())
    print("ninf", json.stringify(@ninf))
    nanv = json.float_value("nan".to_float().unwrap())
    print("nan", json.stringify(@nanv))

    ovf = json.parse("1e999")
    ovfv = ovf.value
    print("ovf", ovf.ok, json.stringify(@ovfv))
    return 0
}
