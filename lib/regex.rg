# RGC standard library: regex
#
# A pure-RGC backtracking engine (byte-based matching):
#   . * + ? {m,n} | ( ) (?: ) [ ] [^ ] ^ $ \d \w \s \b \B \1-\99 and escapes
#   Supports capture groups, backreferences, and greedy/lazy quantifiers.
#
# Usage:
#   import regex
#   rx = regex.compile("(a+)-\\1")
#   m = regex.search(@rx, "xxaa-aa")
#   if m.ok { print(m.groups.get(1)) }

public class ReNode {
    kind: int          # 1 literal, 2 any, 3 class, 4 seq, 5 alt,
                       # 6 star, 7 plus, 8 opt, 9 group, 10 bol, 11 eol,
                       # 12 repeat, 13 boundary, 14 non-boundary, 15 backref
    ch: int
    neg: bool
    ranges: List[int]
    kids: List[ReNode]
    alts: List[ReNode]
    min_rep: int       # repeat: minimum count
    max_rep: int       # repeat: maximum count, -1 means unbounded
    lazy: bool         # whether the quantifier is lazy (*? / +? / ?? / {m,n}?)
    group: int         # group: capture group number (1-based), -1 means (?: )
    ref: int           # backref: the referenced capture group number
}

public class Regex {
    ok: bool
    error: str
    root: ReNode
    ngroups: int
}

# Start/end positions of capture group i live in caps[2*i] / caps[2*i+1]; -1 means the group did not participate.
# caps[0] / caps[1] are reserved for the overall match (filled by search / replace).
class ReState {
    pos: int
    caps: List[int]
}

public class ReMatch {
    ok: bool
    start: int
    end: int
    groups: List[str]   # groups[0] is the overall match; groups[i] is the i-th capture group
}

def re_node(kind: int) -> ReNode {
    n = ReNode()
    n.kind = kind
    n.ch = 0
    n.neg = False
    n.ranges = List[int]()
    n.kids = List[ReNode]()
    n.alts = List[ReNode]()
    n.min_rep = 0
    n.max_rep = 0
    n.lazy = False
    n.group = -1
    n.ref = 0
    return n
}

class ReParser {
    pat: str
    pos: int
    err: str
    ngroups: int

    def fail(self, msg: str) {
        if self.err.len() == 0 {
            self.err = msg
        }
    }

    def peek(self) -> int {
        if self.pos >= self.pat.len() {
            return -1
        }
        return self.pat.char_at(self.pos)
    }

    def digit_at(self, i: int) -> bool {
        if i >= self.pat.len() {
            return False
        }
        c = self.pat.char_at(i)
        return c >= 48 and c <= 57
    }

    def parse_alt(self) -> ReNode {
        first = self.parse_seq()
        if self.peek() != 124 {   # |
            return first
        }
        alts = List[ReNode]()
        alts.push(first)
        while self.peek() == 124 {
            self.pos = self.pos + 1
            alts.push(self.parse_seq())
        }
        n = re_node(5)
        n.alts = alts
        return n
    }

    def parse_seq(self) -> ReNode {
        kids = List[ReNode]()
        while self.pos < self.pat.len() {
            c = self.peek()
            if c == 124 or c == 41 {   # | )
                break
            }
            atom = self.parse_atom()
            if self.err.len() > 0 {
                n = re_node(4)
                n.kids = kids
                return n
            }
            if self.peek() == 42 or self.peek() == 43 or self.peek() == 63 {
                q = self.peek()
                self.pos = self.pos + 1
                kind = 6
                if q == 43 {
                    kind = 7
                } elif q == 63 {
                    kind = 8
                }
                w = re_node(kind)
                if self.peek() == 63 {   # lazy suffix
                    self.pos = self.pos + 1
                    w.lazy = True
                }
                w.kids.push(atom)
                atom = w
            } elif self.peek() == 123 and self.digit_at(self.pos + 1) {
                atom = self.parse_repetition(atom)
            }
            kids.push(atom)
        }
        n = re_node(4)
        n.kids = kids
        return n
    }

    # Called after confirming `{` is followed by at least one digit; accepts {m} / {m,} / {m,n}.
    def parse_repetition(self, atom: ReNode) -> ReNode {
        self.pos = self.pos + 1   # {
        lo = 0
        while self.digit_at(self.pos) {
            lo = lo * 10 + self.pat.char_at(self.pos) - 48
            self.pos = self.pos + 1
        }
        hi = lo
        if self.peek() == 44 {   # ,
            self.pos = self.pos + 1
            if self.peek() == 125 {   # }
                hi = -1
            } else {
                hi = 0
                while self.digit_at(self.pos) {
                    hi = hi * 10 + self.pat.char_at(self.pos) - 48
                    self.pos = self.pos + 1
                }
            }
        }
        if self.peek() != 125 {   # }
            self.fail("invalid repetition")
            return atom
        }
        self.pos = self.pos + 1
        if hi >= 0 and hi < lo {
            self.fail("invalid repetition range")
        }
        n = re_node(12)
        n.min_rep = lo
        n.max_rep = hi
        if self.peek() == 63 {   # lazy suffix
            self.pos = self.pos + 1
            n.lazy = True
        }
        n.kids.push(atom)
        return n
    }

    def parse_escape(self) -> int {
        # The backslash is already consumed; return the character code; the caller handles \d/\w/\s etc.
        if self.pos >= self.pat.len() {
            self.fail("trailing backslash")
            return -1
        }
        c = self.pat.char_at(self.pos)
        self.pos = self.pos + 1
        if c == 110 {   # n
            return 10
        }
        if c == 116 {   # t
            return 9
        }
        if c == 114 {   # r
            return 13
        }
        if c == 102 {   # f
            return 12
        }
        if c == 118 {   # v
            return 11
        }
        return c
    }

    def add_escape_class(self, n: @var ReNode, c: int) {
        if c == 100 {   # d
            n.ranges.push(48)
            n.ranges.push(57)
        } elif c == 119 {   # w
            n.ranges.push(48)
            n.ranges.push(57)
            n.ranges.push(65)
            n.ranges.push(90)
            n.ranges.push(95)
            n.ranges.push(95)
            n.ranges.push(97)
            n.ranges.push(122)
        } elif c == 115 {   # s
            n.ranges.push(9)
            n.ranges.push(10)
            n.ranges.push(13)
            n.ranges.push(13)
            n.ranges.push(32)
            n.ranges.push(32)
        }
    }

    def parse_class(self) -> ReNode {
        n = re_node(3)
        if self.peek() == 94 {   # ^
            n.neg = True
            self.pos = self.pos + 1
        }
        if self.peek() == 93 {   # ] as the first character
            n.ranges.push(93)
            n.ranges.push(93)
            self.pos = self.pos + 1
        }
        while self.pos < self.pat.len() {
            c = self.peek()
            if c == 93 {
                self.pos = self.pos + 1
                return n
            }
            if c == 92 {
                self.pos = self.pos + 1
                e = self.peek()
                if e == 100 or e == 119 or e == 115 {
                    self.add_escape_class(@var n, e)
                    self.pos = self.pos + 1
                    continue
                }
                if e == 98 {   # \b inside a class means backspace
                    n.ranges.push(8)
                    n.ranges.push(8)
                    self.pos = self.pos + 1
                    continue
                }
                lo = self.parse_escape()
                if lo < 0 {
                    return n
                }
                n.ranges.push(lo)
                n.ranges.push(lo)
                continue
            }
            lo = c
            self.pos = self.pos + 1
            if self.peek() == 45 and self.pos + 1 < self.pat.len() and
               self.pat.char_at(self.pos + 1) != 93 {   # -
                self.pos = self.pos + 1
                hi = self.peek()
                if hi == 92 {
                    self.pos = self.pos + 1
                    hi = self.parse_escape()
                } else {
                    self.pos = self.pos + 1
                }
                if hi < 0 {
                    return n
                }
                if hi < lo {
                    self.fail("invalid character class range")
                    return n
                }
                n.ranges.push(lo)
                n.ranges.push(hi)
            } else {
                n.ranges.push(lo)
                n.ranges.push(lo)
            }
        }
        self.fail("unterminated character class")
        return n
    }

    def parse_atom(self) -> ReNode {
        c = self.peek()
        if c < 0 {
            self.fail("unexpected end of pattern")
            return re_node(1)
        }
        if c == 40 {   # (
            self.pos = self.pos + 1
            g = -1
            if self.peek() == 63 {   # (?: non-capturing group
                self.pos = self.pos + 1
                if self.peek() != 58 {   # :
                    self.fail("unsupported group syntax")
                    return re_node(1)
                }
                self.pos = self.pos + 1
            } else {
                self.ngroups = self.ngroups + 1
                g = self.ngroups
            }
            inner = self.parse_alt()
            if self.peek() != 41 {
                self.fail("missing `)`")
                return inner
            }
            self.pos = self.pos + 1
            n = re_node(9)
            n.group = g
            n.kids.push(inner)
            return n
        }
        if c == 91 {   # [
            self.pos = self.pos + 1
            return self.parse_class()
        }
        if c == 46 {   # .
            self.pos = self.pos + 1
            return re_node(2)
        }
        if c == 94 {   # ^
            self.pos = self.pos + 1
            return re_node(10)
        }
        if c == 36 {   # $
            self.pos = self.pos + 1
            return re_node(11)
        }
        if c == 92 {   # backslash
            self.pos = self.pos + 1
            e = self.peek()
            if e == 100 or e == 119 or e == 115 {
                n = re_node(3)
                self.add_escape_class(@var n, e)
                self.pos = self.pos + 1
                return n
            }
            if e == 98 {   # \b word boundary
                self.pos = self.pos + 1
                return re_node(13)
            }
            if e == 66 {   # \B non-word boundary
                self.pos = self.pos + 1
                return re_node(14)
            }
            if e >= 49 and e <= 57 {   # \1-\99 backreference
                ref = 0
                while self.digit_at(self.pos) {
                    ref = ref * 10 + self.pat.char_at(self.pos) - 48
                    self.pos = self.pos + 1
                }
                if ref > self.ngroups {
                    self.fail("invalid backreference")
                }
                n = re_node(15)
                n.ref = ref
                return n
            }
            lo = self.parse_escape()
            n = re_node(1)
            n.ch = lo
            return n
        }
        if c == 42 or c == 43 or c == 63 {
            self.pos = self.pos + 1
            self.fail("quantifier without preceding atom")
            return re_node(1)
        }
        self.pos = self.pos + 1
        n = re_node(1)
        n.ch = c
        return n
    }
}

public def compile(pattern: str) -> Regex {
    p = ReParser()
    p.pat = pattern
    p.pos = 0
    p.err = ""
    p.ngroups = 0
    root = p.parse_alt()
    if p.err.len() == 0 and p.pos != pattern.len() {
        p.fail("unexpected trailing characters")
    }
    r = Regex()
    r.ok = p.err.len() == 0
    r.error = p.err
    r.root = root
    r.ngroups = p.ngroups
    return r
}

# ---------- match state ----------

def new_caps(count: int) -> List[int] {
    out = List[int]()
    i = 0
    while i < count {
        out.push(-1)
        i = i + 1
    }
    return out
}

# Copy st.caps and advance to pos; returns the new state.
def state_from(st: @ReState, pos: int) -> ReState {
    s = ReState()
    s.pos = pos
    s.caps = List[int]()
    i = 0
    while i < st.caps.len() {
        s.caps.push(st.caps.get(i))
        i = i + 1
    }
    return s
}

def start_state(pos: int, caps: @List[int]) -> ReState {
    s = ReState()
    s.pos = pos
    s.caps = List[int]()
    i = 0
    while i < caps.len() {
        s.caps.push(caps.get(i))
        i = i + 1
    }
    return s
}

# Copy r's state and record [start, end) for capture group g.
def set_capture(r: @ReState, g: int, start: int, end: int) -> ReState {
    s = ReState()
    s.pos = r.pos
    s.caps = List[int]()
    i = 0
    while i < r.caps.len() {
        if i == 2 * g {
            s.caps.push(start)
        } elif i == 2 * g + 1 {
            s.caps.push(end)
        } else {
            s.caps.push(r.caps.get(i))
        }
        i = i + 1
    }
    return s
}

def append_states(out: @var List[ReState], xs: @List[ReState]) {
    i = 0
    while i < xs.len() {
        out.push(xs.get(i))
        i = i + 1
    }
}

# ---------- matching ----------

def class_match(n: @ReNode, c: int) -> bool {
    hit = False
    i = 0
    while i + 1 < n.ranges.len() {
        if c >= n.ranges.get(i) and c <= n.ranges.get(i + 1) {
            hit = True
            break
        }
        i = i + 2
    }
    if n.neg {
        return not hit
    }
    return hit
}

def is_word_byte(c: int) -> bool {
    if c >= 48 and c <= 57 {
        return True
    }
    if c >= 65 and c <= 90 {
        return True
    }
    if c >= 97 and c <= 122 {
        return True
    }
    return c == 95
}

# Unified expansion of {min,max} / * / + / ?: returns all results in preference order.
# Empty matches do not continue recursing (avoids infinite loops); but once the minimum is reached, an empty match is a valid result.
def rep_match(child: @ReNode, text: str, st: @ReState, count: int,
              min_rep: int, max_rep: int, lazy: bool) -> List[ReState] {
    out = List[ReState]()
    can_stop = count >= min_rep
    can_more = max_rep < 0 or count < max_rep
    if lazy and can_stop {
        out.push(state_from(st, st.pos))
    }
    if can_more {
        ends = match_node(@child, text, @st)
        i = 0
        while i < ends.len() {
            r = ends.get(i)
            if r.pos == st.pos {
                if count + 1 >= min_rep {
                    out.push(state_from(@r, r.pos))
                }
            } else {
                more = rep_match(@child, text, @r, count + 1, min_rep, max_rep, lazy)
                append_states(@var out, @more)
            }
            i = i + 1
        }
    }
    if not lazy and can_stop {
        out.push(state_from(st, st.pos))
    }
    return out
}

# Return every state reached by matching node from st, ordered by backtracking priority.
def match_node(n: @ReNode, text: str, st: @ReState) -> List[ReState] {
    out = List[ReState]()
    if n.kind == 1 {
        if st.pos < text.len() and text.char_at(st.pos) == n.ch {
            out.push(state_from(st, st.pos + 1))
        }
        return out
    }
    if n.kind == 2 {
        if st.pos < text.len() {
            out.push(state_from(st, st.pos + 1))
        }
        return out
    }
    if n.kind == 3 {
        if st.pos < text.len() and class_match(@n, text.char_at(st.pos)) {
            out.push(state_from(st, st.pos + 1))
        }
        return out
    }
    if n.kind == 10 {
        if st.pos == 0 {
            out.push(state_from(st, st.pos))
        }
        return out
    }
    if n.kind == 11 {
        if st.pos == text.len() {
            out.push(state_from(st, st.pos))
        }
        return out
    }
    if n.kind == 13 or n.kind == 14 {
        before = False
        if st.pos > 0 {
            before = is_word_byte(text.char_at(st.pos - 1))
        }
        after = False
        if st.pos < text.len() {
            after = is_word_byte(text.char_at(st.pos))
        }
        boundary = before
        if after {
            boundary = not before
        }
        if n.kind == 13 and boundary {
            out.push(state_from(st, st.pos))
        }
        if n.kind == 14 and not boundary {
            out.push(state_from(st, st.pos))
        }
        return out
    }
    if n.kind == 4 {
        cur = List[ReState]()
        cur.push(state_from(st, st.pos))
        i = 0
        while i < n.kids.len() {
            child = n.kids.get(i)
            nxt = List[ReState]()
            j = 0
            while j < cur.len() {
                part = cur.get(j)
                ends = match_node(@child, text, @part)
                append_states(@var nxt, @ends)
                j = j + 1
            }
            cur = nxt
            if cur.len() == 0 {
                return cur
            }
            i = i + 1
        }
        return cur
    }
    if n.kind == 5 {
        i = 0
        while i < n.alts.len() {
            child = n.alts.get(i)
            ends = match_node(@child, text, @st)
            append_states(@var out, @ends)
            i = i + 1
        }
        return out
    }
    if n.kind == 6 {   # star
        child = n.kids.get(0)
        return rep_match(@child, text, @st, 0, 0, -1, n.lazy)
    }
    if n.kind == 7 {   # plus
        child = n.kids.get(0)
        return rep_match(@child, text, @st, 0, 1, -1, n.lazy)
    }
    if n.kind == 8 {   # opt
        child = n.kids.get(0)
        return rep_match(@child, text, @st, 0, 0, 1, n.lazy)
    }
    if n.kind == 12 {   # repeat
        child = n.kids.get(0)
        return rep_match(@child, text, @st, 0, n.min_rep, n.max_rep, n.lazy)
    }
    if n.kind == 9 {   # group (group=-1 means non-capturing)
        child = n.kids.get(0)
        rs = match_node(@child, text, @st)
        if n.group < 0 {
            return rs
        }
        i = 0
        while i < rs.len() {
            r = rs.get(i)
            out.push(set_capture(@r, n.group, st.pos, r.pos))
            i = i + 1
        }
        return out
    }
    if n.kind == 15 {   # backref
        g = n.ref
        s = st.caps.get(2 * g)
        e = st.caps.get(2 * g + 1)
        if s < 0 or e < 0 {
            return out
        }
        ln = e - s
        if st.pos + ln <= text.len() {
            ok = True
            i = 0
            while i < ln {
                if text.char_at(st.pos + i) != text.char_at(s + i) {
                    ok = False
                    break
                }
                i = i + 1
            }
            if ok {
                out.push(state_from(st, st.pos + ln))
            }
        }
        return out
    }
    return out
}

# ---------- public API ----------

def new_match() -> ReMatch {
    m = ReMatch()
    m.ok = False
    m.start = -1
    m.end = -1
    m.groups = List[str]()
    return m
}

def build_match(text: str, start: int, st: @ReState, ngroups: int) -> ReMatch {
    m = ReMatch()
    m.ok = True
    m.start = start
    m.end = st.pos
    m.groups = List[str]()
    m.groups.push(text.slice(start, st.pos))
    g = 1
    while g <= ngroups {
        s = st.caps.get(2 * g)
        e = st.caps.get(2 * g + 1)
        if s >= 0 and e >= 0 {
            m.groups.push(text.slice(s, e))
        } else {
            m.groups.push("")
        }
        g = g + 1
    }
    return m
}

def first_state(root: @ReNode, text: str, start: int, ngroups: int) -> ReState {
    caps = new_caps(2 * (ngroups + 1))
    st = start_state(start, @caps)
    ends = match_node(@root, text, @st)
    if ends.len() == 0 {
        return start_state(-1, @caps)
    }
    return ends.get(0)
}

public def is_match(rx: @Regex, text: str) -> bool {
    if not rx.ok {
        return False
    }
    root = rx.root
    ng = rx.ngroups
    start = 0
    while start <= text.len() {
        st = first_state(@root, text, start, ng)
        if st.pos >= 0 {
            return True
        }
        start = start + 1
    }
    return False
}

public def find(rx: @Regex, text: str) -> int {
    if not rx.ok {
        return -1
    }
    root = rx.root
    ng = rx.ngroups
    start = 0
    while start <= text.len() {
        st = first_state(@root, text, start, ng)
        if st.pos >= 0 {
            return start
        }
        start = start + 1
    }
    return -1
}

# Leftmost-first match; returns the overall span and each capture group (groups that did not participate are empty strings).
public def search(rx: @Regex, text: str) -> ReMatch {
    if not rx.ok {
        return new_match()
    }
    root = rx.root
    ng = rx.ngroups
    start = 0
    while start <= text.len() {
        st = first_state(@root, text, start, ng)
        if st.pos >= 0 {
            return build_match(text, start, @st, ng)
        }
        start = start + 1
    }
    return new_match()
}

def group_text(st: @ReState, text: str, start: int, g: int, ngroups: int) -> str {
    if g == 0 {
        return text.slice(start, st.pos)
    }
    if g > ngroups {
        return ""
    }
    s = st.caps.get(2 * g)
    e = st.caps.get(2 * g + 1)
    if s < 0 or e < 0 {
        return ""
    }
    return text.slice(s, e)
}

# Expand $0-$9 / ${n} in the replacement string into capture groups; $$ means a literal `$`.
def expand_repl(repl: str, text: str, start: int, st: @ReState, ngroups: int) -> str {
    out = ""
    i = 0
    while i < repl.len() {
        c = repl.char_at(i)
        if c == 36 {   # $
            if i + 1 < repl.len() and repl.char_at(i + 1) == 36 {
                out = out + "$"
                i = i + 2
                continue
            }
            if i + 1 < repl.len() and repl.char_at(i + 1) == 123 {   # {
                j = i + 2
                num = 0
                digits = 0
                while j < repl.len() and repl.char_at(j) >= 48 and repl.char_at(j) <= 57 {
                    num = num * 10 + repl.char_at(j) - 48
                    j = j + 1
                    digits = digits + 1
                }
                if digits > 0 and j < repl.len() and repl.char_at(j) == 125 {   # }
                    out = out + group_text(@st, text, start, num, ngroups)
                    i = j + 1
                    continue
                }
            }
            if i + 1 < repl.len() {
                d = repl.char_at(i + 1)
                if d >= 48 and d <= 57 {
                    out = out + group_text(@st, text, start, d - 48, ngroups)
                    i = i + 2
                    continue
                }
            }
            out = out + "$"
            i = i + 1
            continue
        }
        out = out + repl.slice(i, i + 1)
        i = i + 1
    }
    return out
}

# Replace all non-overlapping matches; greedy/lazy quantifiers decide the boundaries by their own matching preference.
# $0-$9 / ${n} in repl expand only when the pattern contains capture groups.
public def replace(rx: @Regex, text: str, repl: str) -> str {
    if not rx.ok {
        return text
    }
    root = rx.root
    ng = rx.ngroups
    out = ""
    pos = 0
    while pos <= text.len() {
        st = first_state(@root, text, pos, ng)
        if st.pos >= 0 {
            if ng > 0 {
                out = out + expand_repl(repl, text, pos, @st, ng)
            } else {
                out = out + repl
            }
            if st.pos == pos {
                if pos < text.len() {
                    out = out + text.slice(pos, pos + 1)
                }
                pos = pos + 1
            } else {
                pos = st.pos
            }
        } else {
            if pos < text.len() {
                out = out + text.slice(pos, pos + 1)
            }
            pos = pos + 1
        }
    }
    return out
}
