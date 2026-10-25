# enum_match.rg — matching payload-less enum variants.
#
# A variant without a payload encodes an empty segment in the compiler's slot-kind table and
# split() drops empty segments, so indexing that table by variant index used to read out of
# bounds and segfault rgc itself. A regression shows up as a crashed test process, not as a
# wrong value.

enum Flag {
    On
    Off
}

enum Mixed {
    Empty
    Tagged(int, str)
}

def flag_text(f: Flag) -> str {
    match f {
        case On() => "on"
        case Off() => "off"
    }
}

def mixed_text(m: Mixed) -> str {
    match m {
        case Empty() => "empty"
        case Tagged(n, s) => s + to_string(n)
    }
}

public def test_payloadless_variant_match() -> int {
    on = flag_text(On())
    if on != "on" {
        print("failed flag On: got " + on)
        return 1
    }
    off = flag_text(Off())
    if off != "off" {
        print("failed flag Off: got " + off)
        return 1
    }
    return 0
}

public def test_mixed_payload_match() -> int {
    empty = mixed_text(Empty())
    if empty != "empty" {
        print("failed mixed Empty: got " + empty)
        return 1
    }
    tagged = mixed_text(Tagged(7, "n"))
    if tagged != "n7" {
        print("failed mixed Tagged: got " + tagged)
        return 1
    }
    return 0
}
